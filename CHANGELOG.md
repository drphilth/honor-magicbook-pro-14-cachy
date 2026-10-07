# Changelog

User-facing history of the `honor-fmbp` packages for CachyOS / Arch.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

Versions before 1.0.5-4 were developed and tested before this repository was published, so
they have no tags or release pages of their own.

## [1.0.5-4] — 2026-10-07

Findings from three months of real use and the first big update (kernel 7.1 → 7.2.9).

### Fixed

- **Fingerprint could intermittently stop working until fprintd was restarted.** The bundled
  `honor-fmbp-libfprint-sdcp` is now `1.94.10+sdcpv2-2` (swapped into this release the same day).
  About 1 sensor open in 256 hung fprintd with the device stuck "already claimed", and a verify
  that timed out left the driver in a bad state for the next close. See
  [honor-fmbp-libfprint-sdcp#1](https://github.com/drphilth/honor-fmbp-libfprint-sdcp/issues/1).
- **`dkms.conf` no longer uses the deprecated `CLEAN` directive.** dkms 3.4 prints
  `Deprecated feature: CLEAN` for every kernel on every update. It was a no-op anyway: dkms builds
  in a fresh copy of the source each time.

### Documentation

- **The battery-threshold claim was too strong.** The EC does keep the setting across reboots and a
  cold power-off, but after ~3 months unused it was found reset to `0 100`. The runbook now says so,
  and points at Plasma's own charge-limit setting.
- **TPM auto-unlock is now documented**, including why it breaks: PCR7 covers the firmware's `dbx`,
  which **Windows Update extends** (observed: ~200 new revocations between July and October), after
  which the TPM refuses to unseal. Not tampering — re-seal with the same command. Added to
  Troubleshooting, with a one-off `iwlwifi` firmware crash seen on the same update.
- **Limine claims re-checked for 12.9.0** (binary, hook scripts and source). The config checksum
  still re-enrols only into `limine_x64.efi`, the fallback is never refreshed, and the mismatch
  check is still unconditional. **One claim was wrong:** "an unhashed path is silently skipped" is
  true only of the wallpaper and font. An unhashed kernel or module path panics — in 12.4.2 too.
  `limine-entry-tool` hashes those itself, so nobody following the runbook is exposed.
- The README now says up front that the **login screen has no fingerprint support** (lock screen
  only) — previously only the runbook did.

### Verified on 7.2.9

DSDT override, both DKMS modules, touchpad + touchscreen, HDR and Secure Boot all came up unchanged.

## 1.0.5-3 — 2026-07-14

Fixes from a fresh-eyes review (two independent walkthroughs of the repo as a stranger).

### Fixed

- **`iso/honor-fmbp-install-cachy.sh` crashed on its own success path.** The success message
  interpolated an undefined `$SRC` under `set -u`, so after the offline install *and* both
  verification checks passed, the script died with `SRC: unbound variable` — before printing
  DONE and the entire Secure-Boot guidance block. Introduced in the 1.0.5-2 rewrite of that
  block, i.e. *after* the hardware-verified install run. Also fixed in the same script: a
  reference to a doc filename from the private development repo, and a post-first-boot
  command quoting a directory layout this repo doesn't have.
- **`honor-fmbp-hdr` could still break `mkinitcpio` — the 1.0.5-2 fix closed only half the
  trap.** The EDID generator has a *legitimate* declining path ("not an FMB-P, no eDP-1,
  panel already carries CTA-861"), which prints "this is not fatal" — but the package shipped
  the `FILES+=(…honor-fmbp-hdr.bin)` drop-in unconditionally, so with no blob the next kernel
  update failed initramfs generation for every kernel. The drop-in now guards the `FILES+=`
  on the blob's existence.
- **The retracted "boot-critical / hides the NVMe" claim still shipped inside
  `honor-fmbp-dsdt-update`'s header** (and the runbook's package table). Both now state
  the measured scope: the abort kills touchpad + touchscreen only; the machine boots fine.
- **`dsdt/build.sh` applied its two load-bearing edits with unverified `sed` calls.** An older
  iasl disassembles the same AML differently, the patterns silently miss, and you ship a
  byte-valid but completely unfixed table. Both edits now assert exact match counts before
  and after, and the header documents that the pipeline needs a **global**-SKU input dump.

### Changed

- **The DKMS payload moved from `honor-fmbp/src/` to `honor-fmbp/dkms/`.** `src/` is
  makepkg's own `$srcdir`, so `makepkg -C`/`-c` deleted the tracked driver sources from the
  working tree.
- **`fprintd` is now an optdepends of the metapackage** (alongside the fingerprint driver it
  serves) instead of a hard dependency.
- **The runbook now works for someone with no prior context**: where to get the ISO (and which),
  a Windows/BitLocker pre-flight (§0.5 — suspend BitLocker *before* touching Secure Boot),
  concrete Calamares partitioning (the ESP must be mounted at `/boot`), a triage table so you can
  tell which Secure Boot warnings apply to your situation, the firmware keys (F2/F12), and the
  build machine's actual dependencies. The remaster script now hard-fails without
  `squashfs-tools` instead of silently shipping a degraded ISO, and its repack failure is no
  longer silenced. `SHA256SUMS` added for the prebuilt packages.

## 1.0.5-2 — 2026-07-13

Packaging fixes found by the first real internal-NVMe install. **If you installed 1.0.5-1, upgrade —
your initramfs cannot currently be rebuilt.**

### Fixed

- **`honor-fmbp-hdr` broke `mkinitcpio` on a fresh install.** The package adds
  `/usr/lib/firmware/edid/honor-fmbp-hdr.bin` to `FILES`, but the generator wrote to that path
  **without creating the parent directory** — and `/usr/lib/firmware/edid/` does not exist on a fresh
  Arch/CachyOS system. The install hook silenced the resulting error, so no EDID was produced while
  the drop-in installed anyway: `mkinitcpio` then failed for **every kernel**, and the next kernel
  update would have left an unbootable machine. The generator now creates the directory, the hook
  creates it too, and the hook no longer swallows the generator's errors.
- **The documented path to the pre-first-boot installer was wrong under Ventoy.** The ISO mounts at
  `/run/archiso/bootmnt` only when `dd`'d; Ventoy mounts it at `/run/media/liveuser/COS_*`. The
  runbook now discovers the script instead of hardcoding a path.
- **The installer script asserted "Secure Boot is still OFF" instead of reading it** — false whenever
  the ISO is booted via Ventoy. It now reads `SecureBoot` from efivars and prints accordingly.

### Changed

- **Ventoy is now the recommended way to boot the installer** if you already have sbctl keys
  enrolled. It carries a Microsoft-signed shim, so the ISO boots with **Secure Boot ON** (verified) —
  which means you never touch the BIOS toggle, and your keys survive.

## 1.0.5 — 2026-07-12

First CachyOS release. Ports the Ubuntu enablement (which is at the same version) to
CachyOS/Arch, sharing the same payload — the DKMS sources, udev rules and corrected DSDT are
byte-identical; only the packaging layer differs.

### Added

- **`honor-fmbp-dsdt`** — the corrected DSDT (OEM revision 3), applied the CachyOS way: a
  package-owned `limine-entry-tool` drop-in emits it as a Limine module **before** the main
  initramfs, so the kernel's `acpi_table_upgrade()` consumes it. Snapshot rollbacks inherit it
  (via `limine_history`), so a rollback still finds its root filesystem. The global/Chinese SKU is
  resolved **once**, at install, from the live firmware table.
- **`honor-fmbp-hwmon-dkms`**, **`honor-fmbp-kbdlight-dkms`** — fan RPM and keyboard backlight.
  Both ship a `modules-load.d` entry: the modules are DMI-gated and have **no modalias**, so
  nothing would otherwise autoload them and they would silently never bind.
- **`honor-fmbp-config`** — udev rules + hwdb: touchscreen power/toggle, the Fn-key `e078` quirk,
  and the inhibit for the FTSC1000's bogus second HID collection (which otherwise spams
  `KEY_MICMUTE` ~30/s whenever the panel is touched).
- **`honor-fmbp-hdr`** — a corrected EDID so KWin can see the panel's HDR. The panel declares HDR
  only in a DisplayID 2.0 block; KWin parses only CTA-861. See
  [KDE bug 499673](https://bugs.kde.org/show_bug.cgi?id=499673). Generated from the live panel at
  install time — never shipped prebuilt.
- **`honor-magicbook-pro-14`** — metapackage.
- **`iso/remaster-cachyos-iso.sh`** — builds an installer ISO with the corrected DSDT baked in, so
  the **touchpad works in the installer**. The result is natively bootable (`dd` it; no Ventoy).
  A stock ISO installs fine too — the abort does not touch storage — you would just need a USB mouse.
- **`iso/honor-fmbp-install-cachy.sh`** — run from the live session before the first reboot to put
  the DSDT on the target, so the new system comes up with a working touchpad. Without it the system
  still boots; it just has no touchpad until you install the packages.

### ⛔ Known hazard — Secure Boot

**Flipping the BIOS Secure Boot switch destroys sbctl custom keys** on this machine. Off → on, with
nothing else touched, wipes them and re-provisions the OEM factory store; the correctly-signed
bootloader is then rejected → **"Boot Fail"**. Measured and reproduced in isolation —
[`docs/secureboot-key-wipe-repro.md`](docs/secureboot-key-wipe-repro.md).

**Not Windows' fault** — a normal Win11 boot leaves the keys intact (tested) — and **recoverable in
two minutes with no rescue media**: SB off → boot → `sbctl enroll-keys --microsoft --firmware-builtin`
→ reboot. Secure Boot re-arms itself; the "on" step never needs a BIOS visit.

**The rule we ship: once your keys are enrolled, leave the BIOS Secure Boot toggle alone.**

**shim + MOK was built and abandoned.** It would have put nothing in the firmware key store — but it
is a category error with Limine (which boots the kernel via its own protocol, bypassing the EFI
verification shim exists to perform), and it is not toggle-proof either, since this BIOS has a
separate "disable Microsoft 3rd-party CA" switch that kills a Microsoft-signed shim. Post-mortem,
including the malformed-PE bug that bricked both boot paths:
[`docs/secureboot-key-wipe-repro.md` §C](docs/secureboot-key-wipe-repro.md).

### ⚠️ Known hazard — the Limine config checksum depends on your boot path

The CachyOS wiki tells you to set `ENABLE_ENROLL_LIMINE_CONFIG=yes`. Whether that is right or
catastrophic depends on **which EFI binary your firmware actually launches**. All measured on
hardware (Limine 12.4.2):

- **Firmware boots `\EFI\limine\limine_x64.efi`** via a path-specific NVRAM entry — a normal
  internal install. ✅ Enrolling a checksum is safe: kernel updates **re-enrol it automatically into
  that same binary**. Verified live. It is also the only thing that roots the trust chain past the
  bootloader.
- **Firmware boots the removable fallback `\EFI\BOOT\BOOTX64.EFI`** — USB installs, generic device
  entries. ⛔ **Do not enrol one.** Updates never refresh that binary, so its checksum goes stale and
  the next boot dies with `!!! CHECKSUM MISMATCH FOR CONFIG FILE !!!` — and **Secure Boot off does
  not rescue you**, because the check is unconditional. Recovery needs another OS or live media.

**Always keep `EFI/BOOT/BOOTX64.EFI` signed but checksum-free.** It is the rescue binary — it boots
under any firmware state and any config. **Never copy `limine_x64.efi` over it.**

One thing the wiki gets wrong: Limine does **not** panic when no checksum is enrolled (that panic
string doesn't exist in the binary). And one it gets half right: with a checksum enrolled, an
unhashed `wallpaper:` (or font) is **skipped, not fatal** — an unstyled white boot screen — but an
unhashed kernel or module path *does* panic. (Corrected in 1.0.5-4; this entry originally said every
unhashed path is skipped.)
See [runbook §3.2](docs/install-runbook.md#32-the-limine-config-checksum--it-depends-on-how-your-firmware-boots).

### Notes / differences from the Ubuntu packages

- **No battery-threshold service.** The Ubuntu package restores the charge thresholds at every
  boot, on the premise that "the EC does not persist it across reboots". That premise is **false**
  on BIOS 1.16 — verified by writing the distinguishable `40 70` preset and cold-booting with the
  charger unplugged; it came back `40/70`. Such a service is therefore not merely redundant, it
  **clobbers whatever threshold the user picks in the desktop UI**. Set it once instead:
  `echo '70 90' | sudo tee /sys/devices/platform/huawei-wmi/charge_control_thresholds`
  (the EC accepts only the OEM presets `40 70`, `70 90`, `95 100`).
- **No archive-keyring package.** That deb exists only to add the PPA offline; pacman needs no
  such thing.
- **No dconf default.** That aligned a GNOME extension's presets; Plasma drives
  `charge_control_end_threshold` natively.
- **DKMS modules are not signed**, and do not need to be: Limine boots the kernel via its own
  protocol rather than the EFI stub, so the kernel never enters Secure Boot lockdown
  (`lockdown=none`, `sig_enforce=N`). They load unsigned with Secure Boot **on**.
- **Fingerprint needs no PAM edits** on KDE — Plasma ships a `kde-fingerprint` stack, so the lock
  screen unlocks by finger as soon as a print is enrolled. The **login** screen does not support
  fingerprint; that is an upstream gap
  ([plasma-login-manager#1](https://invent.kde.org/plasma/plasma-login-manager/-/issues/1)), and
  the PAM workaround for it breaks KWallet.

[1.0.5-4]: https://github.com/drphilth/honor-magicbook-pro-14-cachy/releases/tag/v1.0.5-4
