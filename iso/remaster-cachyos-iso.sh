#!/usr/bin/env bash
# remaster-cachyos-iso.sh — bake the corrected DSDT into a CachyOS (archiso) installer ISO
# so it boots NATIVELY (dd to a stick; no Ventoy, no manual GRUB edit).
#
# WHY: the stock FMB-P DSDT aborts at load (NFC0/GNUM), so the touchpad and touchscreen
#   nodes are never created — the installer is unusable without a USB mouse. Baking the
#   corrected DSDT in gives you a working touchpad in the installer.
#
#   It is NOT needed to see the disks. MEASURED on kernel 7.1.3 with the override removed:
#   the abort throws 5 AE_AML_INTERNAL errors and kills touchpad + touchscreen, but BOTH
#   internal NVMe drives enumerate and all their partitions are readable, and USB is fine.
#   A stock ISO installs to the internal drive perfectly well — you just need a mouse.
#   (Ubuntu's installer sees no disks at all, USB or NVMe. That is an Ubuntu-specific,
#   still-unexplained problem, NOT the generic DSDT abort. Do not generalise it.)
#
# HOW (same mechanism as the installed system, just injected at a different layer):
#   an uncompressed early cpio holding kernel/firmware/acpi/dsdt.aml, loaded as the FIRST
#   initrd so the kernel's acpi_table_upgrade() consumes it before it ever parses the
#   firmware DSDT. On the installed system limine-entry-tool emits that as a Limine
#   module_path; here we prepend it to the ISO's own boot configs.
#
#   ./remaster-cachyos-iso.sh <input.iso> <dsdt.aml> <output.iso> [pkgdir]
#
# Needs: xorriso, cpio; plus squashfs-tools + sudo + ~12 GB scratch for the package graft.
# Verified against cachyos-desktop-linux-260628.iso.
#
# --- What archiso actually boots (checked, not assumed) -----------------------------
#   UEFI : /EFI/BOOT/BOOTx64.EFI is **GRUB** (not systemd-boot), and it reads
#          /boot/grub/grub.cfg from the ISO9660 tree. The FAT efiboot.img holds only the
#          EFI binaries, no config — so there is nothing to patch inside it.
#   BIOS : syslinux, /boot/syslinux/*.cfg
#   Both configs live in the ISO filesystem, so both are patched here.
#
# --- The trap that will silently brick the ISO --------------------------------------
#   The kernel cmdline carries archisosearchuuid=<YYYY-MM-DD-HH-MM-SS-00>, and archiso
#   locates its own ISO by matching that against the **ISO9660 volume creation
#   timestamp**. xorriso stamps a NEW timestamp on any repack by default, after which the
#   live system cannot find itself and boot dies in the initramfs. We therefore read the
#   source timestamp and force it back with -volume_date uuid.
set -euo pipefail

IN="${1:?usage: remaster-cachyos-iso.sh <input.iso> <dsdt.aml> <output.iso> [pkgdir]}"
AML="${2:?missing dsdt.aml}"
OUT="${3:?missing output.iso}"
PKGDIR="${4:-}"          # optional: dir of built *.pkg.tar.zst -> grafted on as /honor-fmbp

[ -r "$IN"  ] || { echo "no such iso: $IN";  exit 1; }
[ -r "$AML" ] || { echo "no such aml: $AML"; exit 1; }
command -v xorriso >/dev/null || { echo "need xorriso"; exit 1; }
command -v cpio    >/dev/null || { echo "need cpio";    exit 1; }
if [ -n "$PKGDIR" ]; then
  # The package graft re-squashes the live root; without these tools we would silently ship a
  # degraded ISO (phantom KEY_MICMUTE spam in the live session). Hard-fail instead.
  command -v unsquashfs >/dev/null && command -v mksquashfs >/dev/null \
    || { echo "need squashfs-tools (unsquashfs/mksquashfs) when a package dir is given"; exit 1; }
fi
[ -e "$OUT" ] && { echo ">> removing existing $OUT"; rm -f "$OUT"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo ">> [1/5] build the early-ACPI cpio from $AML"
# The kernel only honours an UNCOMPRESSED cpio whose member path is exactly
# kernel/firmware/acpi/<table>.aml, and only if it sits at the very front of the initrd
# chain. Also: the AML's OEM revision MUST exceed the firmware's or it is silently ignored.
mkdir -p "$tmp/ov/kernel/firmware/acpi"
cp "$AML" "$tmp/ov/kernel/firmware/acpi/dsdt.aml"
( cd "$tmp/ov" && find kernel | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet ) > "$tmp/acpi_override.img"
rev=$(od -An -tu1 -j 24 -N 1 "$AML" | tr -d ' ')
echo "   acpi_override.img: $(stat -c%s "$tmp/acpi_override.img") bytes (DSDT OEM revision $rev)"

echo ">> [2/5] preserve the archiso volume timestamp (archisosearchuuid depends on it)"
vdate=$(xorriso -indev "$IN" -pvd_info 2>/dev/null | sed -n 's/^Creation Time: *//p' | tr -d ' ')
[ -n "$vdate" ] || { echo "!! could not read the ISO creation time — refusing to repack blind"; exit 1; }
echo "   volume creation time: $vdate"

echo ">> [3/5] patch every boot config that loads an initrd"
cfgs=()
while IFS= read -r f; do
  f="${f#\'}"; f="${f%\'}"; [ -n "$f" ] || continue
  cfgs+=("$f")
done < <(xorriso -indev "$IN" -find / -name 'grub.cfg' -or -name 'loopback.cfg' -or -name '*.cfg' 2>/dev/null \
         | tr -d "'" | grep -E '/boot/(grub|syslinux)/')

maps=()
patched=0
for cfg in "${cfgs[@]}"; do
  local_out="$tmp/$(echo "$cfg" | tr '/' '_')"
  xorriso -osirrox on -indev "$IN" -extract "$cfg" "$local_out" >/dev/null 2>&1 || continue
  # GRUB:     `initrd a b`   -> multiple files, concatenated in order (ours must be FIRST)
  # syslinux: `INITRD a,b`   -> comma-separated, same ordering rule
  # Entries with no initrd (memtest, UEFI shell) are left alone by construction.
  before=$(grep -cE '^[[:space:]]*(initrd|INITRD)[[:space:]]' "$local_out" || true)
  [ "$before" -gt 0 ] || continue
  sed -i -E \
    -e 's|^([[:space:]]*)initrd[[:space:]]+(.*)$|\1initrd /acpi_override.img \2|' \
    -e 's|^([[:space:]]*)INITRD[[:space:]]+(.*)$|\1INITRD /acpi_override.img,\2|' \
    "$local_out"
  echo "   $cfg  ($before initrd line(s))"
  maps+=(-map "$local_out" "$cfg")
  patched=$((patched + before))
done
[ "$patched" -gt 0 ] || { echo "!! no initrd lines found — wrong ISO layout, refusing to write a dud"; exit 1; }

echo ">> [3b/5] graft the offline package repo + pre-first-boot installer"
# WHY: the freshly-installed system has no DSDT yet, so its first boot comes up with no
# touchpad. It BOOTS fine (storage is unaffected by the abort), but you would be reaching for
# a mouse again. Carrying the packages on the ISO lets us put the DSDT on the target from the
# live session, offline, before that first reboot.
if [ -n "$PKGDIR" ]; then
  [ -d "$PKGDIR" ] || { echo "!! no such package dir: $PKGDIR"; exit 1; }
  mkdir -p "$tmp/honor-fmbp"
  n_pkg=0
  for p in "$PKGDIR"/*.pkg.tar.zst; do
    [ -e "$p" ] || continue
    cp "$p" "$tmp/honor-fmbp/"; n_pkg=$((n_pkg + 1))
  done
  [ "$n_pkg" -gt 0 ] || { echo "!! no *.pkg.tar.zst in $PKGDIR"; exit 1; }
  ls "$tmp/honor-fmbp" | grep -q '^honor-fmbp-dsdt-' \
    || { echo "!! honor-fmbp-dsdt is missing — that is the one that restores the touchpad"; exit 1; }

  helper="$(dirname "$0")/honor-fmbp-install-cachy.sh"
  [ -r "$helper" ] || { echo "!! missing $helper"; exit 1; }
  install -Dm755 "$helper" "$tmp/honor-fmbp/honor-fmbp-install-cachy.sh"

  # Record which DSDT variant this ISO carries. The live session's
  # /sys/firmware/acpi/tables/DSDT is ALREADY our override, so SKU auto-detection in a chroot
  # would just read back whatever we baked in — and would answer "global" on a Chinese unit.
  # The helper pins this value instead of detecting.
  case "$(basename "$AML")" in
    *chinese*) sku=chinese ;;
    *)         sku=global  ;;
  esac
  printf '%s\n' "$sku" > "$tmp/honor-fmbp/SKU"
  echo "   $n_pkg package(s) + installer, SKU=$sku  ->  /honor-fmbp"
  maps+=(-map "$tmp/honor-fmbp" /honor-fmbp)
else
  echo "   (skipped — no package dir given; the ISO still boots the installer with a working"
  echo "    touchpad, you just install the packages yourself afterwards.)"
fi

echo ">> [3c/5] bake the udev rules into the LIVE session (touchscreen + phantom KEY_MICMUTE)"
# WHY: the DSDT rides in as an early cpio because the KERNEL consumes it before any root
# filesystem exists. udev rules cannot use that path — they have to be present in the live
# root, which is a squashfs. So this is genuine surgery: unsquash, add, re-squash.
#
# It matters on a touchscreen laptop: the FTSC1000 exposes a bogus second HID collection that
# spams KEY_MICMUTE ~30/s whenever the panel is touched — i.e. exactly what a user does while
# poking at an installer. The rule inhibits that device.
#
# Source of truth is the honor-fmbp-config PACKAGE, not a second copy of the rules — so this
# cannot drift from what the installed system gets.
if [ -n "$PKGDIR" ] && command -v unsquashfs >/dev/null && command -v mksquashfs >/dev/null; then
  cfgpkg=$(ls "$PKGDIR"/honor-fmbp-config-*.pkg.tar.zst 2>/dev/null | head -1 || true)
  if [ -z "$cfgpkg" ]; then
    echo "   !! honor-fmbp-config package not found in $PKGDIR — skipping (live session keeps the mute spam)"
  else
    sfs=$(xorriso -indev "$IN" -find /arch -name 'airootfs.sfs' 2>/dev/null | tr -d "'" | grep -m1 airootfs.sfs || true)
    [ -n "$sfs" ] || { echo "!! could not locate airootfs.sfs in the ISO"; exit 1; }

    # Work on DISK, never in /tmp: the extracted root is ~10 GB and /tmp is usually tmpfs (RAM).
    # The live root must keep root:root ownership and its xattrs — unsquashfs cannot do that
    # as a normal user, and a root filesystem owned by uid 1000 is a broken live system, not a
    # cosmetic warning. So every squashfs step below runs under sudo.
    command -v sudo >/dev/null || { echo "!! need sudo to un/re-squash the live root"; exit 1; }
    work="$(dirname "$OUT")/.remaster-work.$$"
    sudo rm -rf "$work"; mkdir -p "$work"
    trap 'sudo rm -rf "$work"; rm -rf "$tmp"' EXIT

    xorriso -osirrox on -indev "$IN" -extract "$sfs" "$work/airootfs.sfs" >/dev/null 2>&1
    comp=$(unsquashfs -s "$work/airootfs.sfs" | awk '/Compression/{print $2}')
    blk=$(unsquashfs -s "$work/airootfs.sfs" | awk '/Block size/{print $3}')
    echo "   squashfs: compression=$comp block=$blk  (repack must match, or the live boot dies)"

    echo "   unsquashing (this is the slow part)…"
    sudo unsquashfs -q -f -d "$work/root" "$work/airootfs.sfs" >/dev/null

    # Pull the rules straight out of the package.
    mkdir -p "$work/pkg"
    tar -xf "$cfgpkg" -C "$work/pkg" 2>/dev/null
    n_rule=0
    for f in "$work/pkg"/usr/lib/udev/rules.d/*.rules "$work/pkg"/usr/lib/udev/hwdb.d/*.hwdb; do
      [ -e "$f" ] || continue
      rel="${f#$work/pkg/}"
      sudo install -Dm644 -o root -g root "$f" "$work/root/$rel"
      echo "     + /$rel"
      n_rule=$((n_rule + 1))
    done
    [ "$n_rule" -gt 0 ] || { echo "!! honor-fmbp-config shipped no udev rules — refusing to repack blind"; exit 1; }

    # The hwdb is compiled into a binary index; shipping the .hwdb text alone does nothing.
    if command -v systemd-hwdb >/dev/null; then
      sudo systemd-hwdb update --root "$work/root" >/dev/null 2>&1 \
        && echo "     hwdb index rebuilt" \
        || echo "     !! systemd-hwdb update failed — the Fn-key quirk will not apply in the live session"
    fi

    echo "   re-squashing (slower still — xz)…"
    sudo rm -f "$work/airootfs.new.sfs"
    sudo mksquashfs "$work/root" "$work/airootfs.new.sfs" \
      -comp "$comp" -b "$blk" -noappend -no-progress -quiet
    # hand the artefacts back so xorriso (running as you) can read them
    sudo chown "$(id -u):$(id -g)" "$work/airootfs.new.sfs"
    sha512sum "$work/airootfs.new.sfs" | awk '{print $1"  airootfs.sfs"}' > "$work/airootfs.sha512"

    maps+=(-map "$work/airootfs.new.sfs" "$sfs")
    maps+=(-map "$work/airootfs.sha512" "$(dirname "$sfs")/airootfs.sha512")
    echo "   baked $n_rule file(s) into the live root; sha512 regenerated"
  fi
else
  echo "   (skipped — needs a package dir and squashfs-tools. The INSTALLED system is unaffected;"
  echo "    only the live session keeps the phantom KEY_MICMUTE spam.)"
fi

echo ">> [4/5] repack (preserving El Torito + isohybrid MBR/GPT so it stays dd-able)"
xorriso -indev "$IN" -outdev "$OUT" \
  -volume_date uuid "$vdate" \
  -boot_image any replay \
  -map "$tmp/acpi_override.img" /acpi_override.img \
  "${maps[@]}" \
  -end > "$tmp/xorriso-repack.log" 2>&1 \
  || { echo "!! xorriso repack FAILED — last lines:"; tail -20 "$tmp/xorriso-repack.log"; exit 1; }

echo ">> [5/5] verify the output"
ok=1
xorriso -indev "$OUT" -find /acpi_override.img >/dev/null 2>&1 \
  && echo "   ✓ /acpi_override.img present" || { echo "   ✗ override missing"; ok=0; }
newdate=$(xorriso -indev "$OUT" -pvd_info 2>/dev/null | sed -n 's/^Creation Time: *//p' | tr -d ' ')
[ "$newdate" = "$vdate" ] \
  && echo "   ✓ volume timestamp preserved ($newdate) — archisosearchuuid still matches" \
  || { echo "   ✗ volume timestamp CHANGED ($vdate -> $newdate): the live system will not find its ISO"; ok=0; }
n=$(xorriso -indev "$OUT" -report_el_torito plain 2>/dev/null | grep -c 'El Torito boot img' || true)
[ "$n" -ge 2 ] \
  && echo "   ✓ El Torito BIOS+UEFI boot images intact ($n)" \
  || { echo "   ✗ boot images lost ($n) — the ISO will not boot"; ok=0; }
if [ -n "$PKGDIR" ]; then
  xorriso -indev "$OUT" -find /honor-fmbp/honor-fmbp-install-cachy.sh >/dev/null 2>&1 \
    && echo "   ✓ offline package repo + pre-first-boot installer present" \
    || { echo "   ✗ /honor-fmbp missing"; ok=0; }
fi
echo "   size: $(stat -c%s "$OUT" | numfmt --to=iec)"
[ "$ok" = 1 ] || { echo "!! verification FAILED — do not use $OUT"; exit 1; }

cat <<EOF

done -> $OUT

Write it straight to a stick (no Ventoy needed):
    sudo dd if=$OUT of=/dev/sdX bs=4M status=progress oflag=sync

SECURE BOOT: a dd'd stick will NOT boot with SB on — archiso's GRUB is unsigned (no shim),
so you must turn SB off in the BIOS. That is fine for a FIRST install (you need SB off anyway to
reach Setup Mode, where sbctl enrols your keys).

BUT if you ALREADY have sbctl keys enrolled, put this ISO on a VENTOY stick instead: Ventoy
carries a Microsoft-signed shim and boots it with SECURE BOOT ON (verified on this hardware).
That matters, because turning the BIOS Secure Boot switch off DESTROYS enrolled keys on this
firmware. Ventoy lets you install without ever touching that toggle.
EOF

if [ -n "$PKGDIR" ]; then cat <<'EOF'

AFTER Calamares finishes, BEFORE the first reboot, run:

    sudo "$(find /run/archiso/bootmnt /run/media -name honor-fmbp-install-cachy.sh 2>/dev/null | head -1)"

This puts the DSDT on the new system so it comes up with a working touchpad. Skip it and the
system still boots — storage is unaffected by the DSDT abort — you just have no touchpad until
you install the packages.
EOF
fi

cat <<'EOF'

Confirm the override took, from the live session:
    sudo dmesg | grep -iE 'Table Upgrade|GINF|AE_AML'
Expect "ACPI: Table Upgrade: override [DSDT- HONOR- ARL]" and ZERO GINF/AE_AML errors.
EOF
