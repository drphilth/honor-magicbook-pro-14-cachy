# HONOR MagicBook Pro 14 (2025) — CachyOS / Arch

CachyOS enablement for the **HONOR MagicBook Pro 14 2025 (FMB-P)** — Intel Core Ultra
(Arrow Lake-H), OLED. Everything installs as pacman packages.

Out of the box the **touchpad and touchscreen do not work**: a load-time abort in the OEM ACPI DSDT
kills half the ACPI namespace, so those input devices are never created. This repo ships the
corrected DSDT plus everything else the hardware needs, packaged so it stays applied across kernel
updates.

> **Storage is fine, though.** Verified on kernel 7.1.3 by booting with the override removed: the
> abort throws 5 `AE_AML_INTERNAL` errors and kills the touchpad and touchscreen, but **internal
> NVMe enumerates normally and every partition is readable** (verified on a unit with two NVMe
> drives fitted). So a stock CachyOS ISO *can* install to the internal drive — you'll just have to
> use a USB mouse. The tooling here saves you that, it doesn't unblock you.
>
> (Ubuntu behaves differently: its installer sees *no* disks at all, USB or NVMe. That is an
> Ubuntu-specific problem and is still unexplained — it is **not** the generic DSDT abort.)

> **Target: CachyOS with the Limine bootloader and KDE Plasma** (its defaults). Kernel 7.x.
>
> ### ⛔ Secure Boot: read [the warning](#secure-boot) before enrolling keys.
> On this laptop, **flipping the BIOS Secure Boot switch destroys custom (sbctl) keys** and leaves the
> machine at "Boot Fail". Measured, reproduced in isolation, [fully documented](docs/secureboot-key-wipe-repro.md).
> Not Windows' fault (tested). **Recovery takes two minutes and no rescue media** — but the rule is:
> **once your keys are enrolled, leave that toggle alone.**

## What works

With these packages, effectively everything:

| Component | State |
|---|---|
| Touchpad | ✅ fixed by the corrected DSDT |
| NVMe, USB, USB-C | ✅ native — **unaffected** by the DSDT abort (measured) |
| Touchscreen (FocalTech FTSC1000) | ✅ fixed in the same DSDT (ACPI `PowerResource` injection) + udev quirk |
| Display / Intel Arc graphics, WiFi 6E, Bluetooth, webcam, suspend/resume | ✅ native |
| Audio (Intel cAVS / SOF) | ✅ `sof-firmware` (pulled in by the metapackage) |
| **HDR** (OLED panel) | ✅ via a corrected EDID — KWin cannot see this panel's HDR without it ([why](#hdr)) |
| Fan RPM | ✅ `honor-fmbp-hwmon` (DKMS, EC reverse-engineered) |
| Keyboard backlight | ✅ `honor-fmbp-kbdlight` (DKMS, EC reverse-engineered) |
| Caps-Lock + mic-mute LEDs, Fn keys | ✅ native (+ an hwdb quirk) |
| Battery charge thresholds | ✅ `huawei-wmi`; the EC keeps them across reboots — but not always forever, see the runbook |
| **Fingerprint** (EgisTec ET171, SDCP match-on-chip) | ✅ enroll + verify + KDE lock-screen unlock (the login screen has no fingerprint support — upstream gap) |
| Secure Boot | ✅ your own keys (sbctl + Limine) — ⚠️ **but the BIOS SB toggle destroys them.** [Read this](#secure-boot) |
| Suspend | ✅ s2idle — this hardware is **S0ix-only**, do not force S3 |

## Installing

### Fresh install (recommended path)

A stock ISO *will* install to the internal drive — the DSDT abort doesn't touch storage. But the
**touchpad is dead in the installer**, and dead again on the first boot of the new system, so you'd
be driving the whole thing with a USB mouse. Baking the DSDT into the ISO avoids that, and gets the
fix onto the target before you ever boot it.

Full step-by-step: **[`docs/install-runbook.md`](docs/install-runbook.md)**. In brief:

1. On any Linux machine, remaster the [CachyOS Desktop ISO](https://cachyos.org/download/) with
   the DSDT and the packages grafted on (needs `xorriso`, `cpio`, `squashfs-tools`, ~12 GB scratch).
   Prebuilt packages ship at the repo root (`sha256sum -c SHA256SUMS` to verify) — building them
   yourself needs an Arch-family machine (`makepkg`):

   ```sh
   (cd honor-fmbp && makepkg -f)                  # OPTIONAL — prebuilts are at the repo root
   mkdir -p /tmp/pkgs && cp ./*.pkg.tar.zst honor-fmbp/*.pkg.tar.zst /tmp/pkgs/ 2>/dev/null

   ./iso/remaster-cachyos-iso.sh \
       cachyos-desktop-linux-XXXXXX.iso \
       dsdt/patched/dsdt.global.aml \
       cachyos-desktop-linux-XXXXXX-MB.iso \
       /tmp/pkgs

   sudo dd if=cachyos-desktop-linux-XXXXXX-MB.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

2. Boot the stick and run the Calamares installer (bootloader: **Limine**). The touchpad works
   and the internal NVMe is visible. A `dd`'d stick needs **Secure Boot OFF** (archiso's GRUB is
   unsigned); if you already have sbctl keys enrolled, boot the ISO via **Ventoy** instead — it
   carries a Microsoft-signed shim, so Secure Boot stays ON and your keys survive
   ([runbook §2](docs/install-runbook.md)).

3. **Before the first reboot**, put the DSDT on the new system — offline, from the live session
   (remastered ISO only — a stock ISO doesn't carry the script or the packages; you'd install
   them after the first boot instead, mouse in hand):

   ```sh
   sudo "$(find /run/archiso/bootmnt /run/media -name honor-fmbp-install-cachy.sh 2>/dev/null | head -1)"
   ```

   The installed system doesn't have the DSDT yet, so without this its first boot comes up with **no
   touchpad**. It will boot — storage is unaffected by the abort — you'd just be reaching for a mouse
   again. This installs `honor-fmbp-dsdt` + `honor-fmbp-config` into the target and verifies them.

4. Reboot, install the rest, and enrol your Secure Boot keys — [runbook §3–§5](docs/install-runbook.md).
   Enrolling a Platform Key **re-arms Secure Boot by itself**; there is no "turn it back on in the
   BIOS" step, and going into the BIOS to look for one is [the one thing that destroys your keys](#secure-boot).

### Existing install

Already running CachyOS on this machine (e.g. on a USB disk, which *does* boot without the DSDT)?

```sh
cd honor-fmbp && makepkg -si
```

## Packages

| Package | Contents |
|---|---|
| `honor-fmbp-dsdt` | Corrected DSDT + the Limine drop-in that loads it — restores touchpad + touchscreen |
| `honor-fmbp-hwmon-dkms` | Fan tachometer driver |
| `honor-fmbp-kbdlight-dkms` | Keyboard backlight driver |
| `honor-fmbp-config` | udev rules + hwdb (touchscreen, phantom `KEY_MICMUTE` inhibit, Fn-key quirk) |
| `honor-fmbp-hdr` | Corrected EDID so KWin can see the panel's HDR |
| `honor-magicbook-pro-14` | Metapackage — pulls in the core set; HDR and fingerprint are `optdepends` (opt-in) |
| [`honor-fmbp-libfprint-sdcp`](https://github.com/drphilth/honor-fmbp-libfprint-sdcp) | SDCP fingerprint driver (separate repo — different upstream) |

## The DSDT fix

The firmware DSDT runs a broken method (`GNUM`→`GINF`) at **table-load time**, throwing
`AE_AML_INTERNAL`, which **aborts the whole table load**. Half the ACPI namespace never builds, so
the **touchpad node is never created**. The fix deletes that load-time call and bumps the OEM
revision so the kernel accepts our table. The same corrected table also injects the
`PowerResource`/`_PR0` the OEM omitted from the touchscreen.

**What the abort does and doesn't break** (measured on kernel 7.1.3, override removed):

| | stock DSDT |
|---|---|
| `AE_AML_INTERNAL` / `GINF` errors | 5 |
| Touchpad, touchscreen | ❌ dead |
| Internal NVMe (disks *and* partitions) | ✅ fine |
| USB | ✅ fine |

So this is an **input** fix, not a storage one. Anything you read (including earlier versions of
this README) claiming the abort hides the NVMe on kernel 7.x is wrong.

Root cause write-up: [`docs/dsdt-root-cause.md`](docs/dsdt-root-cause.md). Rebuild it yourself from
your own machine's tables with [`dsdt/build.sh`](dsdt/build.sh).

**How it's applied (this is the Arch-specific part).** Not via the initramfs, as on Debian —
CachyOS boots **Limine**. The package ships `/etc/limine-entry-tool.d/10-honor-fmbp-dsdt.conf`
containing `KERNEL_CMDLINE[default]+="initrd=/acpi_override.img"`. `limine-entry-tool` converts each
`initrd=` into a Limine `module_path` emitted **before** the main initramfs — exactly what the
kernel's `acpi_table_upgrade()` needs. `limine-snapper-sync` also content-addresses a copy into
`limine_history/`, so **snapshot rollbacks keep their DSDT** — otherwise a rollback would come up
with no touchpad.

> **Don't hand-edit the boot entries in `/boot/limine.conf`** — they are generated, and your edits
> vanish on the next kernel update. (The **theme block at the top** is different: it is user-owned and
> *does* survive regeneration, which is how you hash the `wallpaper:` line — see
> [runbook §3.2](docs/install-runbook.md#32-the-limine-config-checksum--it-depends-on-how-your-firmware-boots).)
> And never edit `/etc/default/limine` from a package: that file belongs to the user.

## Secure Boot

> # ⛔ READ THIS BEFORE ENROLLING ANY KEYS
>
> ## On this laptop, **flipping the BIOS Secure Boot switch DESTROYS custom (sbctl) keys.**
>
> Turn Secure Boot **off** and back **on** — nothing else, no commands, no Windows — and your
> enrolled keys are **gone**, replaced by the OEM factory set. Your correctly-signed bootloader is
> then rejected and the machine shows **"Boot Fail"**.
>
> **This is measured, not theorised** — reproduced deliberately and in isolation. Full protocol and
> results: [`docs/secureboot-key-wipe-repro.md`](docs/secureboot-key-wipe-repro.md).
>
> **It is not fatal, and it is not Windows' fault.** A normal Windows 11 boot leaves the keys alone
> (tested). The BIOS toggle is the whole problem. But a setup whose safety rule is *"never touch the
> Secure Boot switch"* — a switch that exists to be flipped, to boot a live USB or try something — is
> **not something we are willing to recommend to other people.**
>
> **This does not strand you, and the recovery never needs the firmware menu:**
> ```sh
> # BIOS: SB off (this is what puts the firmware into Setup Mode) → boot CachyOS →
> sudo sbctl enroll-keys --microsoft --firmware-builtin
> # reboot — Secure Boot re-arms ITSELF. Do not touch the toggle again.
> ```
> Two minutes, no rescue media. Nothing is lost: your keys persist at `/var/lib/sbctl/keys` and the
> on-disk signatures stay valid.
>
> **The rule is simply: once your keys are enrolled, leave the BIOS Secure Boot toggle alone.** You
> never need it — enrolling a Platform Key re-arms Secure Boot by itself.

### How this firmware actually behaves (all measured)

- **The BIOS has no key-management menu** — only Enable/Disable, and there is no "Restore Factory
  Keys" option to go looking for.
- **"Secure Boot: Disabled" is not an enforcement flag.** It **clears the Platform Key** and puts the
  firmware into **Setup Mode**. That is *why* `sbctl enroll-keys` works after turning SB off — and why
  turning it back on re-provisions the **factory** key store, destroying yours. The firmware exposes
  `PKDefault`/`KEKDefault`/`dbDefault` and a `RestoreFactoryDefault` variable; that restore path is
  almost certainly what runs when you flip the switch back on.
- **Enrolling a PK re-arms Secure Boot by itself.** No BIOS visit needed to turn it back on.
- **In Setup Mode, `PK`/`KEK`/`db` read as EMPTY regardless of what the store contains.** You cannot
  audit the key store with Secure Boot off — every reading must be taken with SB **on**.
- **A normal Windows 11 boot is harmless to the keys** (tested). Windows is not the problem.

### Why not shim + MOK?

The obvious alternative is a Microsoft-signed **shim** with our key in `MokList` — which would put
nothing in the firmware key store, and so have nothing for the toggle to destroy. **We built it. It
does not work here, and we are not pursuing it.**

- **shim + Limine is a category error.** shim exists to verify the *next* image loaded via EFI
  `LoadImage`. **Limine does not load the kernel that way** — it uses its own boot protocol, which
  bypasses EFI verification entirely. shim would check Limine and then have no say in anything after
  it. Limine enforces its own **BLAKE2B config-and-file hashes** instead; that *is* its Secure Boot
  story, and it is the supported one.
- **shim is not toggle-proof here either.** This BIOS has a separate **"disable Microsoft 3rd-party
  CA"** toggle. Flip that and the Microsoft-signed shim stops verifying. The two designs have
  mirror-image failure modes — one dies on the Secure Boot toggle, the other on the 3rd-party-CA
  toggle. Neither survives a determined visit to the BIOS menu.
- **The price is enormous:** abandoning Limine for GRUB or systemd-boot, reworking the DSDT drop-in,
  losing snapshot boot, and MOK-signing every DKMS module.

Full post-mortem, including the malformed-PE bug that bricked both boot paths while we tried:
[`docs/secureboot-key-wipe-repro.md` §C](docs/secureboot-key-wipe-repro.md).

### Gotchas that will bite you

- **You must sign `/boot/EFI/BOOT/BOOTX64.EFI`, not just `limine_x64.efi`.** On a generic/removable
  boot entry the firmware launches the *fallback* path, and Limine installs that as an **unsigned
  copy of itself**. Sign only the obvious one and you get **"Boot Fail"** with no explanation. Also
  note `sbctl sign -s` silently declines to *track* an already-signed file, so nothing gets
  re-signed on update and Boot Fail returns later — strip with `sbattach --remove` first.
- **The Limine config checksum depends on how your firmware boots you.** If it launches
  `\EFI\limine\limine_x64.efi` via a path-specific NVRAM entry (a normal internal install), enrolling
  a checksum is safe and **self-maintaining** across kernel updates — and it is the only thing that
  roots the trust chain past the bootloader. If it launches the removable fallback
  `\EFI\BOOT\BOOTX64.EFI` (USB installs, generic device entries), **do not enrol one**: updates never
  refresh that binary, so it goes stale and panics — **and Secure Boot off does not rescue you**,
  because the check is unconditional. Either way, **keep the fallback signed but checksum-free**; it
  is your rescue binary. Measured the hard way; see
  [runbook §3.2](docs/install-runbook.md#32-the-limine-config-checksum--it-depends-on-how-your-firmware-boots).

Kernels do **not** need signing: Limine boots them via its own protocol, bypassing the EFI stub, so
the kernel never enters lockdown — which also means **DKMS modules load unsigned** under Secure Boot.

## HDR

The OLED panel is HDR-capable and the kernel plumbs it correctly — but **KWin reports it as
`HDR: incapable`**. The panel declares its HDR only inside a **DisplayID 2.0** extension block, and
KWin (via `libdisplay-info`) parses only **CTA-861** blocks. This affects a whole class of OLED
laptops — upstream [KDE bug 499673](https://bugs.kde.org/show_bug.cgi?id=499673), still open.

`honor-fmbp-hdr` fixes it properly: it re-states the panel's **own** HDR values (BT2020RGB; SDR
gamma + ST2084; 1600 / 702.5 / 0.012 cd/m²) in an appended CTA-861 block and loads it via
`drm.edid_firmware=`. Nothing is invented — the values are read out of the panel's own DisplayID
block, and the result is `edid-decode`-conformant. This is strictly better than that bug's
documented workaround (`KWIN_FORCE_ASSUME_HDR_SUPPORT=1`), which supplies no metadata and yields
only EDR. The EDID is generated **from your live panel at install time**, never shipped prebuilt.

Not needed on GNOME, where HDR already works.

## Repo layout

```
honor-fmbp/     the pacman packaging: one split PKGBUILD -> six packages, plus the payload
                (DKMS sources, udev rules, DSDT variants, helper scripts)
dsdt/           the DSDT pipeline: build.sh (extract -> fix -> compile) + the corrected tables
iso/            remaster-cachyos-iso.sh (builds the DSDT-carrying installer ISO) and
                honor-fmbp-install-cachy.sh (run from the live session before the first reboot)
docs/           install-runbook.md, dsdt-root-cause.md, secureboot-key-wipe-repro.md (the
                evidence record behind the Secure Boot warnings)
```

## Changelog

See [`CHANGELOG.md`](CHANGELOG.md).

## Credits

- The DSDT defect was independently reported by
  [denis-bb](https://github.com/denis-bb/honor-fmb-p-dsdt) and
  [colorcube](https://github.com/colorcube/Linux-on-Honor-Magicbook-14-Pro); the root cause and the
  minimal fix here were derived from this machine's own tables.
- Fingerprint: the [`egismoc-sdcp`](https://github.com/TenSeventy7/libfprint-egismoc-sdcp) fork, plus
  EvernightFedora's PR #1 (the ET171 device support).
- A community CachyOS workaround by
  [GeekpoolDeluxe](https://github.com/GeekpoolDeluxe) independently confirmed the Limine
  `module_path` route for the DSDT.

## License

GPL-2.0. See [`LICENSE`](LICENSE).
