#!/usr/bin/env bash
# honor-fmbp-install-cachy.sh — run from the CachyOS LIVE session AFTER Calamares finishes
# but BEFORE the first reboot. Chroots the freshly-installed system and installs the
# honor-fmbp packages from the local repo bundled on this ISO, ENTIRELY OFFLINE.
#
# WHY: the freshly-installed system has no DSDT yet, so its first boot comes up with a DEAD
#   TOUCHPAD. It boots fine — MEASURED on kernel 7.1.3, the DSDT abort kills touchpad and
#   touchscreen but leaves storage completely alone (NVMe enumerates, every partition readable)
#   — you would simply be back on a USB mouse. This script puts the DSDT on the target
#   from the live session so the first boot is usable.
#
#   It is a convenience, not a rescue. Skipping it does not brick anything.
#
# WHAT IT INSTALLS (the DSDT + pure-file quirks; no builds):
#     honor-fmbp-dsdt     corrected DSDT -> target ESP + a limine-entry-tool drop-in, so the
#                         first boot has a working touchpad + touchscreen
#     honor-fmbp-config   udev/hwdb input quirks (pure files, no build)
#
# DELIBERATELY NOT installed here: the DKMS drivers, fingerprint and HDR packages. They build
# against the running kernel / read the live panel, so they go in on the first boot, from the
# copies bundled next to this script on the installer stick (or a clone of the repo):
#     sudo pacman -U /run/media/*/*/honor-fmbp/*.pkg.tar.zst
#
# Usage (from the live-session terminal):
#     sudo "$(find /run/archiso/bootmnt /run/media -name honor-fmbp-install-cachy.sh 2>/dev/null | head -1)" [TARGET]
#     (the ISO mounts at /run/archiso/bootmnt when dd'd, /run/media/liveuser/COS_* under Ventoy)
#
# TARGET may be a mounted root directory OR a block device, which we mount ourselves. With no
# argument we look for the root Calamares left mounted, else offer an interactive pick. The
# RUNNING live system is always excluded, so this can never target itself.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "must run as root (sudo)"; exit 1; }

log() { printf '>> %s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

pkgs=("$here"/*.pkg.tar.zst)
[ -e "${pkgs[0]}" ] || die "no packages next to this script ($here) — was the ISO built with a package dir?"

# ---------------------------------------------------------------------------------------
# Find the target root.
# ---------------------------------------------------------------------------------------
TARGET="${1:-}"
cleanup_mnt=""
cleanup() {
    [ -n "$cleanup_mnt" ] || return 0
    for d in dev/pts dev proc sys boot ""; do
        umount -q "$cleanup_mnt/$d" 2>/dev/null || true
    done
    rmdir "$cleanup_mnt" 2>/dev/null || true
}
trap cleanup EXIT

if [ -z "$TARGET" ]; then
    # Calamares mounts the new root under /tmp/calamares-root-* while it works.
    for c in /tmp/calamares-root-* /mnt /target; do
        [ -d "$c/etc" ] && [ -d "$c/usr" ] && { TARGET="$c"; break; }
    done
fi
[ -n "$TARGET" ] || die "could not find the installed root. Pass it explicitly, e.g.:
    sudo $0 /dev/nvme0n1p2      (a block device — I will mount it)
    sudo $0 /mnt                (an already-mounted root)"

if [ -b "$TARGET" ]; then
    cleanup_mnt="$(mktemp -d)"
    log "mounting $TARGET at $cleanup_mnt"
    # CachyOS's default layout is btrfs with the root in subvolume @.
    mount -o subvol=@ "$TARGET" "$cleanup_mnt" 2>/dev/null || mount "$TARGET" "$cleanup_mnt" \
        || die "could not mount $TARGET"
    TARGET="$cleanup_mnt"
fi

[ -d "$TARGET/etc" ] && [ -d "$TARGET/usr" ] || die "$TARGET does not look like a Linux root"
[ "$(stat -c%d /)" != "$(stat -c%d "$TARGET")" ] || die "refusing to target the RUNNING live system"
log "target root: $TARGET"

# ---------------------------------------------------------------------------------------
# The ESP must be mounted inside the target, or honor-fmbp-dsdt-update has nowhere to write
# the override and limine-update has no config to rewrite.
# ---------------------------------------------------------------------------------------
if ! mountpoint -q "$TARGET/boot"; then
    esp=$(awk '$2=="/boot" && $3=="vfat" {print $1}' "$TARGET/etc/fstab" 2>/dev/null | head -1)
    if [ -n "$esp" ]; then
        esp_dev=$(blkid -t "${esp%%=*}=${esp#*=}" -o device 2>/dev/null | head -1 || true)
        [ -n "$esp_dev" ] || esp_dev="$esp"
        log "mounting the target ESP ($esp_dev) at $TARGET/boot"
        mount "$esp_dev" "$TARGET/boot" || die "could not mount the target ESP"
    fi
fi
mountpoint -q "$TARGET/boot" || die "the target's ESP is not mounted at $TARGET/boot — cannot write the DSDT override"

# ---------------------------------------------------------------------------------------
# Force the SKU. In the live session /sys/firmware/acpi/tables/DSDT is ALREADY OUR OVERRIDE,
# not the firmware's table, so SKU auto-detection would simply read back whichever variant
# this ISO baked in — and would confidently answer "global" on a Chinese-SKU machine. The ISO
# records what it carries; we pin that into the target instead of detecting.
# ---------------------------------------------------------------------------------------
sku="global"
[ -r "$here/SKU" ] && sku="$(tr -d '[:space:]' < "$here/SKU")"
log "pinning DSDT SKU to '$sku' (from the ISO; auto-detection is unreliable in a live chroot)"
install -Dm644 /dev/stdin "$TARGET/etc/honor-fmbp/dsdt-force" <<EOF
$sku
EOF

# ---------------------------------------------------------------------------------------
# Install, offline, in the chroot. honor-fmbp-dsdt's scriptlet does the real work:
# resolve the SKU -> write acpi_override.img to the ESP -> limine-update.
# ---------------------------------------------------------------------------------------
for d in dev dev/pts proc sys; do
    mkdir -p "$TARGET/$d"
    mountpoint -q "$TARGET/$d" || mount --rbind "/$d" "$TARGET/$d"
done

offline_pkgs=()
for p in "${pkgs[@]}"; do
    case "$(basename "$p")" in
        honor-fmbp-dsdt-*|honor-fmbp-config-*) offline_pkgs+=("$p") ;;
    esac
done
[ "${#offline_pkgs[@]}" -gt 0 ] || die "no honor-fmbp-dsdt package on the ISO — that is the one that restores the touchpad"

log "installing into the target (offline):"
printf '     %s\n' "${offline_pkgs[@]##*/}"
cp "${offline_pkgs[@]}" "$TARGET/tmp/"
chroot "$TARGET" /bin/bash -c \
    "pacman -U --noconfirm --needed $(printf '/tmp/%s ' "${offline_pkgs[@]##*/}")" \
    || die "pacman failed inside the target"
rm -f "$TARGET"/tmp/honor-fmbp-*.pkg.tar.zst

# ---------------------------------------------------------------------------------------
# Verify — do not take pacman's word for it.
# ---------------------------------------------------------------------------------------
log "verifying"
ok=1
if [ -f "$TARGET/boot/acpi_override.img" ]; then
    echo "   ✓ acpi_override.img on the target ESP ($(stat -c%s "$TARGET/boot/acpi_override.img") bytes)"
else
    echo "   ✗ acpi_override.img MISSING from the target ESP"; ok=0
fi
if grep -q 'acpi_override' "$TARGET/boot/limine.conf" 2>/dev/null; then
    n=$(grep -c 'acpi_override' "$TARGET/boot/limine.conf")
    echo "   ✓ limine.conf references the override ($n entries)"
else
    echo "   ✗ limine.conf does NOT reference the override"; ok=0
fi

if [ "$ok" = 1 ]; then
    cat <<'EOF'

>> DONE — the installed system will come up with a working touchpad.

   The rest of the packages (DKMS drivers, fingerprint, HDR) are on this ISO next to
   this script — plug the stick back in after the first boot and install them:
       sudo pacman -U /run/media/*/*/honor-fmbp/*.pkg.tar.zst
EOF

    # Do NOT assert the Secure Boot state — READ it. This script used to hardcode
    # "Secure Boot is still OFF (it had to be, to boot this installer)", which is false
    # whenever the ISO is booted via Ventoy (its Microsoft-signed shim keeps SB on).
    sb_var=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
    sb="unknown"
    [ -r "$sb_var" ] && sb=$(od -An -t u1 "$sb_var" 2>/dev/null | awk '{print $NF}')

    case "$sb" in
      1) cat <<'EOF'

   Secure Boot is currently ON (you booted this installer through a signed shim, e.g. Ventoy).
   The freshly-installed Limine is UNSIGNED, so the new system will "Boot Fail" until you
   sign it. Sign BOTH, or the fallback will bite you:
       sudo sbctl sign -s /boot/EFI/limine/limine_x64.efi
       sudo sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI
   If you already have sbctl keys enrolled in firmware (e.g. from another install), copy
   /var/lib/sbctl across and sign with those — do NOT run enroll-keys again, it would
   REPLACE the firmware key store and stop the other system booting.
EOF
         ;;
      0) cat <<'EOF'

   Secure Boot is currently OFF. To turn it on, follow docs/install-runbook.md §3:
   enrol keys with sbctl, then sign BOTH limine_x64.efi AND /boot/EFI/BOOT/BOOTX64.EFI
   or you will get "Boot Fail" (the firmware launches the fallback, not the obvious one).
   Do NOT toggle Secure Boot back on in the BIOS — enrolling keys re-arms it by itself.
EOF
         ;;
      *) echo; echo "   Could not read the Secure Boot state (no efivars?). Check with: sbctl status" ;;
    esac
else
    die "verification FAILED — the DSDT is not in place; the new system will boot but with no touchpad."
fi
