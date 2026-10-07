# CachyOS install runbook — HONOR MagicBook Pro 14 2025 (FMB-P)

Install CachyOS on the FMB-P with **Secure Boot ON** and full hardware support: corrected DSDT,
touchpad, touchscreen, fan RPM, keyboard backlight, fingerprint, HDR.

**Status: every step below was executed and verified on hardware (2026-07-12/13, including a full
fresh install to the internal NVMe)**, except where
explicitly flagged. Where an earlier version of this document was wrong, the correction is called
out — because the wrong versions were plausible.

> Packaging: [`honor-fmbp/PKGBUILD`](../honor-fmbp/PKGBUILD)

---

## 0. What you need

- The FMB-P. Everything here was verified on BIOS **1.16** (check yours: firmware setup, or
  `sudo dmidecode -s bios-version` from any Linux). Other versions are probably fine but
  unverified — and if you intend to update the BIOS via HONOR's Windows tooling, do it **before**
  you shrink or wipe Windows.
- **The CachyOS Desktop ISO** from <https://cachyos.org/download/> — verify its checksum against
  the one published there. This runbook was validated against `cachyos-desktop-linux-260628.iso`;
  any recent desktop ISO should behave the same (the scripts don't depend on a specific release).
- A USB stick (≥4 GB) for the installer.
- **A second machine** (or your existing Linux install) to build the remastered ISO. Any distro
  works — the remaster script needs no Arch tooling (see §1 for its dependencies). Only *building
  the packages yourself* needs `makepkg` (Arch-only); prebuilt copies ship at the repo root, with
  a `SHA256SUMS`, so you don't have to.
- **Firmware keys on this laptop:** setup is entered with **F2** at power-on, the one-time boot
  menu with **F12**.

### 0.5 If Windows is staying: do this first, from Windows

This guide supports wiping the disk *or* dual-booting — decide now, because the safe order is
Windows-first:

1. **Save your BitLocker recovery key** (Settings → Privacy & security → Device encryption, or
   <https://aka.ms/myrecoverykey>) even if you think you won't need it.
2. **Suspend BitLocker protection** (Windows: `manage-bde -protectors -disable C: -RebootCount 0`,
   or the "Suspend protection" button) **before you touch anything in the firmware**. Your first
   act in §2 may be turning Secure Boot off, which changes PCR7 — with BitLocker armed, the next
   Windows boot then demands the recovery key. Re-enable protection when all the Secure Boot work
   (§3) is finished.
3. **Dual-booting on one disk? Shrink the Windows partition from inside Windows** (Disk
   Management → Shrink Volume). Do not resize a BitLocker NTFS volume from Linux.
4. Leave the Windows ESP alone — you will create a separate, bigger ESP for Linux in §2.
- If you also dual-boot **Ubuntu with TPM-LUKS auto-unlock**: expect to re-seal it afterwards (§6).

---

## 1. Build the installer ISO — strongly recommended

The stock DSDT aborts at load (NFC0/GNUM), so the **touchpad and touchscreen are dead in a stock
installer**. Baking the corrected DSDT into the ISO gives you a working touchpad throughout, and
gets the fix onto the target before you first boot it.

> **It is not required to see the disks.** Measured on kernel 7.1.3 with the override removed: the
> abort throws 5 `AE_AML_INTERNAL` errors and kills touchpad + touchscreen, but **internal NVMe
> enumerates fully and every partition is readable** (verified on a unit with two NVMe drives
> fitted), and USB is fine. A stock ISO installs to the internal drive perfectly well — you just
> need a USB mouse.
>
> (Ubuntu's installer sees *no* disks at all, USB or NVMe. That is an **Ubuntu-specific**,
> still-unexplained problem — **not** the generic DSDT abort. Don't generalise from it, as an earlier
> version of this runbook wrongly did.)

**What the build machine needs** (any distro): `xorriso`, `cpio`, `squashfs-tools`, `sudo`, and
roughly **12 GB of free disk** next to the output ISO (the live root gets unpacked). If
`squashfs-tools` is missing the script still produces a bootable ISO but **silently skips baking
the udev quirks into the live session** — you'd get the touchscreen's phantom mic-mute spam during
the install. Install it.

**Build the packages first** (or use the prebuilt ones — see below), then bake both them *and* the
DSDT into the ISO — the packages have to ride along, for the reason in §2.5:

```sh
# Prebuilt packages ship at the repo root (verify with `sha256sum -c SHA256SUMS`) — use those
# and skip the makepkg line if your build machine isn't Arch (makepkg is Arch-only).
(cd honor-fmbp && makepkg -f)
mkdir -p /tmp/honorpkgs && cp ./*.pkg.tar.zst honor-fmbp/*.pkg.tar.zst /tmp/honorpkgs/ 2>/dev/null

./iso/remaster-cachyos-iso.sh \
    cachyos-desktop-linux-XXXXXX.iso \
    dsdt/patched/dsdt.global.aml \
    cachyos-desktop-linux-XXXXXX-MB.iso \
    /tmp/honorpkgs                       # <-- grafts an offline repo at /honor-fmbp
```

> Chinese-SKU unit? Pass `dsdt/patched/dsdt.chinese.aml`. The ISO records which variant it
> carries and pins it into the target — it does **not** auto-detect, because in the live session
> the ACPI table is already *our override*, so detection would just read back what we baked in.

This produces a **natively bootable** ISO — no Ventoy, no manual GRUB edit:

```sh
sudo dd if=cachyos-desktop-linux-XXXXXX-MB.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

<details><summary>What the script does, and the trap it avoids</summary>

archiso's UEFI loader `/EFI/BOOT/BOOTx64.EFI` is **GRUB** (not systemd-boot), reading
`/boot/grub/grub.cfg` from the ISO9660 tree; BIOS uses syslinux. The script prepends an
uncompressed early cpio (`kernel/firmware/acpi/dsdt.aml`) as the **first** initrd in both, so the
kernel's `acpi_table_upgrade()` consumes it before parsing the firmware DSDT.

The trap: the cmdline carries `archisosearchuuid=…`, and archiso finds its own ISO by matching that
against the **ISO9660 volume creation timestamp**. xorriso stamps a *new* timestamp on any repack,
after which the live system cannot find itself and dies in the initramfs. The script preserves the
timestamp and verifies it survived.
</details>

---

## 2. Boot the installer and install

1. **Boot the installer. Use Ventoy if you already have keys enrolled.**

   **A `dd`'d stick will NOT boot with Secure Boot on.** archiso's UEFI loader
   (`/EFI/BOOT/BOOTx64.EFI`, which is GRUB) is **completely unsigned** — not Microsoft-signed, no
   shim. Verify for yourself: `sbverify --list` on it reports *"No signature table present"*. So a
   `dd`'d stick means **BIOS → Secure Boot: Disabled**, then **F12**.

   > ### ✅ Ventoy boots this ISO with Secure Boot ON — and that matters
   > [Ventoy](https://www.ventoy.net/) is a multiboot USB tool: you install it onto the stick once,
   > then drop ISO files onto the stick's filesystem and pick one at boot. It ships its own
   > Microsoft-signed shim with an enrolled MOK, and chainloads the ISO, which bypasses SB
   > verification for whatever it loads. **Verified on this machine.** (Note: a stick is either a
   > Ventoy stick *or* a `dd`'d stick — switching between the two means re-imaging it.)
   >
   > Use it if you have **already enrolled sbctl keys** (e.g. on another install), because
   > turning Secure Boot off in the BIOS **destroys them** (see §3). Ventoy lets you install without
   > ever touching that toggle. On a first-ever install with no keys yet, either route is fine.

   **Fresh install, no keys yet?** Secure Boot off costs you nothing — you need it off anyway for §3,
   since that's the only way to reach Setup Mode on this BIOS. The flow is:
   **SB off → install → enrol keys → reboot (SB re-arms itself).**
2. The **touchpad works** in the installer (the DSDT is baked in). The internal NVMe is visible —
   it would be on a stock ISO too; the DSDT abort doesn't hide storage.
3. Run the Calamares installer:
   - **Bootloader: Limine** (the CachyOS default; the rest of this runbook assumes it).
   - **Partitioning — the one hard requirement: the ESP must end up mounted at `/boot`** (FAT32,
     `boot`/`esp` flag). That is CachyOS's own Limine layout and everything downstream assumes it —
     §2.5's installer locates the ESP via the fstab `/boot` vfat entry, and every §3 signing path
     is `/boot/EFI/...`. **Do not use `/boot/efi`** (other distros' muscle memory) — it will fail
     §2.5 with "the target's ESP is not mounted at /boot" and break the Secure Boot steps.
     - *Erase disk* (wiping the machine): fine as-is — Calamares produces the right layout.
     - *Manual / dual-boot*: create a **new** ESP of **2–4 GB** (it holds every kernel +
       initramfs + snapshot copies; the Windows ESP is ~200 MB — don't reuse it, don't touch it),
       mount point `/boot`, plus your root. Encryption is fine (LUKS + btrfs works).
   - ⚠️ **Check the target disk by model and size.** The NVMe device numbers (`nvme0n1` /
     `nvme1n1`) **swap between boots** on this machine — never trust the letter.
4. Before rebooting, put the DSDT on the new system → §2.5.

---

## 2.5 Before the first reboot — put the DSDT on the new system

The **installed system doesn't have the DSDT yet**, so its first boot comes up with a **dead
touchpad**. It *boots* fine — storage is unaffected by the abort — you'd just be back on a USB mouse.
This step saves you that, and is the tidiest way to get the fix in.

From the live session:

```sh
sudo "$(find /run/archiso/bootmnt /run/media -name honor-fmbp-install-cachy.sh 2>/dev/null | head -1)"
```

It finds the root Calamares just installed (pass it explicitly if not: a mount point or a block
device), mounts the target's ESP, installs `honor-fmbp-dsdt` + `honor-fmbp-config` **offline** via
chroot, and then **verifies** `acpi_override.img` is on the ESP and referenced by `limine.conf`. It
refuses to report success otherwise.

The DKMS drivers, fingerprint and HDR packages are deliberately **not** installed here (they build
against the running kernel / read the live panel). They go in after the first boot — §4.

> Skipping it isn't fatal — you can install the packages after the first boot (§4) instead. You'll
> just need a mouse until you do.

Now reboot.

---

## 3. Secure Boot — enrol your own keys

**Get your bearings first — the scary warnings below have a precise scope:**

| Your situation | What it means |
|---|---|
| **Fresh machine, never enrolled sbctl keys** (most readers) | Nothing is at risk *yet*. Follow §3.1→§3.4 top to bottom; the toggle hazard becomes live the moment §3.1 completes, and §3.4 tells you the one thing not to do afterwards. |
| **Keys already enrolled** (e.g. by another install on this machine) | The hazard is live now. Never touch the BIOS Secure Boot toggle; boot installers via Ventoy (§2); if adding a second install, copy `/var/lib/sbctl` — **never** run `enroll-keys` again. |

The happy path is short: **§3.1 enrol → §3.3 sign both binaries → §3.4 reboot (Secure Boot re-arms
itself)**. §3.2 is an optional hardening step with its own decision table; §3.6 is recovery.

> ## ⛔ WARNING — read before doing any of this
>
> **On this laptop, flipping the BIOS Secure Boot switch DESTROYS the keys you are about to enrol.**
> Off → on, with nothing else touched, wipes them and re-provisions the OEM factory set; your
> correctly-signed bootloader is then rejected → **"Boot Fail"**. Measured and reproduced in isolation:
> [`secureboot-key-wipe-repro.md`](secureboot-key-wipe-repro.md).
>
> It is **not Windows' fault** (a normal Win11 boot leaves the keys alone — tested), and it is
> **recoverable in about two minutes with no rescue media** (see [§3.6](#36-if-it-all-goes-wrong)).
>
> **The rule: once you have enrolled, never touch the BIOS Secure Boot toggle again.** You will not
> need to. **Enrolling a Platform Key re-arms Secure Boot by itself** — there is no step in this
> runbook that asks you to go back into the firmware menu, and that is deliberate.
>
> *(We also built the obvious alternative — a Microsoft-signed **shim** with our key in `MokList`,
> which would put nothing in the firmware store for the toggle to destroy. **It does not work with
> Limine, and we abandoned it.** Reasons, and the bug that bricked both boot paths while we tried:
> [`secureboot-key-wipe-repro.md` §C](secureboot-key-wipe-repro.md).)*

**The BIOS has no key-management menu at all** — only Enable/Disable. That looks like a dead end
for custom keys, and I originally concluded (wrongly) that it was one. It isn't:

> **Turning Secure Boot OFF puts this firmware into Setup Mode.** That is the window in which
> `sbctl` can enrol keys. There is no "Restore Factory Keys" option — do not go looking for one.

```sh
sudo pacman -S --needed sbctl sbsigntools efitools   # efitools = efi-readvar, used to verify below
```

### 3.1 Enrol your keys

Secure Boot should still be **Disabled** from §2 — so the firmware is already in Setup Mode. (If you
re-enabled it, turn it back off and reboot.)

```sh
sudo sbctl status            # expect: Setup Mode: Enabled
sudo sbctl create-keys
sudo sbctl enroll-keys --microsoft --firmware-builtin
sudo sbctl status            # expect: Vendor Keys: microsoft builtin-db
```

Both flags matter, for different reasons:

- **`--microsoft` retains Microsoft's certificates**, which is what keeps **Windows** and a
  shim-based **Ubuntu** bootable. **Verified:** the MS certs land in `db` (read them back with
  `efi-readvar -v db | grep -i microsoft`) and both other OSes still boot afterwards. Omitting it
  *should* stop them booting — nothing would vouch for their Microsoft-signed loaders. We reasoned
  that; we did not test it, and neither should you.
- **`--firmware-builtin` folds in the OEM's own KEK and `db`** (`FermatB_DB`) alongside Microsoft's,
  so anything the factory trusted stays bootable. It touches only `db` and `KEK`, never your PK.
  This firmware genuinely exposes its defaults (`PKDefault`, `KEKDefault`, `dbDefault`), so the flag
  has real content to enrol. It is also what the [CachyOS
  wiki](https://wiki.cachyos.org/configuration/secure_boot_setup/) recommends.

  ⚠️ The wiki warns that on **ASUS/Gigabyte** boards this flag produces duplicate `builtin-db`
  entries and a Secure Boot Violation. This is an Insyde/HONOR board and we have not seen that — but
  **check the `sbctl status` output above.** If `Vendor Keys` reads `builtin-db builtin-db`, re-enter
  Setup Mode and re-enrol with `--microsoft` alone.

### 3.2 The Limine config checksum — it depends on how your firmware boots

Limine can bind a BLAKE2B checksum of `limine.conf` into its own EFI binary
(`ENABLE_ENROLL_LIMINE_CONFIG=yes` + `limine-enroll-config`). That checksum is what *roots* the trust
chain: `limine.conf` sits unsigned on the ESP, and the per-file hashes inside it (covering the kernel,
the initramfs, and our DSDT override) mean nothing unless the config itself is pinned to the signed
binary. Without it, Secure Boot verifies **the bootloader and nothing past it**.

So you want it — **but only if your firmware boots Limine by path.** Find out which:

```sh
sudo efibootmgr | grep BootCurrent          # e.g. BootCurrent: 0003
sudo efibootmgr | grep -i '^Boot0003'       # what does that entry point at?
```

| The firmware boots… | Enrol a checksum? |
|---|---|
| **`\EFI\limine\limine_x64.efi`** via a path-specific NVRAM entry — what a normal internal install gets | ✅ **Yes.** Kernel updates re-enrol it automatically. Self-maintaining. |
| **`\EFI\BOOT\BOOTX64.EFI`** — the removable fallback, used for USB installs and generic device entries | ⛔ **No. This will brick you.** |

> ### ⛔ Why the fallback path is fatal
>
> A kernel update rewrites `limine.conf` and re-enrols the checksum — **but only into
> `EFI/limine/limine_x64.efi`. It never touches `EFI/BOOT/BOOTX64.EFI`.** If the fallback is what your
> firmware launches, it keeps the *old* checksum while the config moves on, and the next boot dies:
>
> ```
> PANIC: !!! CHECKSUM MISMATCH FOR CONFIG FILE !!!
> ```
>
> ### ⛔⛔ And Secure Boot off does NOT rescue you
>
> **The checksum check is not gated on Secure Boot.** Once enrolled, Limine enforces it
> unconditionally. Turning Secure Boot off does not get you back in — it just wipes your keys on the
> way past. **Recovery requires another OS or live media.** We did this to ourselves; it cost a rescue
> boot into a second Linux install.

**Therefore, whatever you do: keep `EFI/BOOT/BOOTX64.EFI` signed but checksum-FREE.** A signed,
checksum-free Limine boots under any firmware state and any `limine.conf` — it is your rescue binary,
and this firmware is erratic about NVRAM entries, so you *will* land on it eventually. **Never copy
`limine_x64.efi` over `BOOTX64.EFI`** — that is precisely how you arm the self-destruct.

If your boot path qualifies, enable it:

```sh
# /etc/default/limine — this file is yours; packages never touch it
ENABLE_ENROLL_LIMINE_CONFIG=yes
```

Then hash the wallpaper, or Limine will skip it and you get an unstyled white boot screen. (The
wallpaper and the menu font are the only paths Limine *skips* when unhashed; an unhashed **kernel or
module** path panics. You will not hit that: `limine-entry-tool` hashes every kernel, initramfs and
our DSDT module itself — only the hand-written theme block is yours to hash.)

```sh
sudo b2sum /boot/limine-splash.png     # append as  ...limine-splash.png#<hash>
sudo nano /boot/limine.conf            # the theme block at the top is user-owned; the edit persists
sudo limine-update                     # re-enrols the checksum to match
```

**What the wiki gets wrong** (measured on this hardware on Limine 12.4.2; re-checked against the
12.9.0 source):

| Wiki says | Reality |
|---|---|
| Panics if no checksum is enrolled | **No.** That panic string doesn't exist in the binary. It boots fine. |
| Every path must be hashed or it panics | **Half-true.** Kernel and module paths: yes, they panic. The wallpaper and font are skipped with a warning instead — hence the white screen. |
| — | It panics **only** on a *mismatch* of an *enrolled* checksum. |

### 3.3 Sign the bootloader — and the fallback, which is the part everyone misses

```sh
sudo sbctl verify                                   # lists what is unsigned
sudo sbctl sign -s /boot/EFI/limine/limine_x64.efi
sudo sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI
sudo sbctl list-files                               # BOTH must be listed
```

⚠️ **`/boot/EFI/BOOT/BOOTX64.EFI` is the binary the firmware actually launches** on a removable
or generic boot entry, and Limine installs it as an **unsigned copy of itself**. Sign only
`limine_x64.efi` and you get **"Boot Fail"** from the BIOS with no explanation.

⚠️ **`sbctl sign -s` silently refuses to *track* an already-signed file** ("File has already been
signed") and `sbctl list-files` stays empty — so nothing is re-signed on updates and Boot Fail
returns after the next kernel/Limine upgrade. There is no `--force`. If a file is already signed,
strip and re-sign it:

```sh
sudo sbattach --remove /boot/EFI/limine/limine_x64.efi
sudo sbctl sign -s     /boot/EFI/limine/limine_x64.efi
sudo sbattach --remove /boot/EFI/BOOT/BOOTX64.EFI
sudo sbctl sign -s     /boot/EFI/BOOT/BOOTX64.EFI
sudo sbctl list-files                # BOTH must be listed
```

### 3.4 Reboot — do NOT go into the BIOS

**Just reboot.** Enrolling a Platform Key **re-arms Secure Boot by itself** on this firmware. Going
into the BIOS to "turn Secure Boot on" is the one action that destroys everything you just did.

```sh
sudo sbctl status        # Secure Boot: Enabled, Setup Mode: Disabled, Vendor Keys: microsoft builtin-db
```

Then **sanity-check the other OSes still boot** (F12 → Windows / Ubuntu). If either fails, the
Microsoft certs did not make it into `db` — re-enter Setup Mode and re-enrol.

### 3.5 Kernel updates need nothing from you

Either way, a kernel update is hands-off:

- **Booting `limine_x64.efi` by path, checksum enrolled:** the update rewrites `limine.conf` and
  **re-enrols the checksum into that same binary automatically**. Verified live — we forced a config
  change, rebooted, and it booted clean.
- **Booting the fallback, no checksum:** nothing to go stale.

The one thing that is *never* maintained is a checksum inside `EFI/BOOT/BOOTX64.EFI`. Don't put one
there — see §3.2.

### 3.6 If it all goes wrong

**Boot Fail from the BIOS** (a stray Secure Boot toggle wiped your keys) — recover from CachyOS
itself, no rescue media, no firmware menu for the *"on"* step:

```sh
# BIOS → Secure Boot: OFF     (puts the firmware in Setup Mode; CachyOS then boots unverified)
# boot CachyOS, then:
sudo sbctl enroll-keys --microsoft --firmware-builtin
# reboot — Secure Boot re-arms ITSELF.
```

To be precise about the toggle, since this recovery *uses* it: flipping it **to OFF is safe** (that
is the recovery's first step — it clears the PK and opens Setup Mode). What destroys keys is
flipping it back **to ON**, which re-provisions the factory store over yours. You never need the
"on" direction: enrolling a Platform Key turns Secure Boot back on by itself.

Nothing is lost: your keys persist at `/var/lib/sbctl/keys` and the on-disk signatures stay valid.
The **OEM Platform Key** is the one thing gone for good — but nothing needs it to boot, so it costs
you nothing.

**A Limine `CHECKSUM MISMATCH` panic** is a different animal, and **Secure Boot off will not fix it**
(see §3.2). You need another OS or live media. Mount the CachyOS ESP and put back a checksum-free
Limine on the fallback path:

```sh
# from any other Linux, with the CachyOS ESP mounted at /mnt/esp:
cp /mnt/esp/EFI/BOOT/BOOTX64.EFI.bak /mnt/esp/EFI/BOOT/BOOTX64.EFI    # if you kept a backup
# otherwise: copy a fresh /usr/share/limine/BOOTX64.EFI in, then re-sign it from CachyOS afterwards
```

**A white / unstyled Limine screen** is not a fault — it means a checksum *is* enrolled and the
`wallpaper:` path has no hash, so Limine skipped it. Cosmetic. Fix per §3.2.

> 💡 **Keep a backup.** Before any Secure Boot experiment, `sudo cp /boot/EFI/BOOT/BOOTX64.EFI
> /boot/EFI/BOOT/BOOTX64.EFI.bak`. A signed, checksum-free Limine boots under any firmware state and
> any `limine.conf`, which makes it a perfect rescue binary.

**Kernels do not need signing.** Limine boots the kernel via its own protocol, bypassing EFI
`LoadImage`, so the kernel never enters Secure Boot lockdown. That also means **DKMS modules load
unsigned** even with SB on (`/sys/kernel/security/lockdown` = `[none]`, `sig_enforce` = `N`).

---

## 4. Install the remaining packages

If you did §2.5, `honor-fmbp-dsdt` and `honor-fmbp-config` are already in. Install the rest — they
need the running kernel (DKMS) or the live panel (HDR), so they could not go in from the chroot.
They are already on the installer stick, so this works offline too:

```sh
# udisks mounts the stick at /run/media/<user>/<label> — hence the two globs
sudo pacman -U /run/media/*/*/honor-fmbp/*.pkg.tar.zst    # from the installer stick
```

or download the same packages from the
[latest release](https://github.com/drphilth/honor-magicbook-pro-14-cachy/releases/latest):

```sh
sha256sum -c SHA256SUMS                 # in the directory holding the downloaded assets
sudo pacman -U ./*.pkg.tar.zst
```

or rebuild from the repo:

```sh
# from a clone of this repo:
(cd honor-fmbp && makepkg -si)          # builds + installs the whole split package set
```

The fingerprint driver lives in its own repo (different upstream):

```sh
git clone https://github.com/drphilth/honor-fmbp-libfprint-sdcp.git
cd honor-fmbp-libfprint-sdcp/arch && makepkg -si
```

The full set:

| Package | What it does |
|---|---|
| `honor-fmbp-dsdt` | Corrected DSDT → ESP + a Limine drop-in. Restores touchpad + touchscreen (the machine boots without it — you'd just need a mouse). SKU resolved at install: auto-detected from the firmware table on a normal install, pinned by the ISO's marker when the live session already runs our override (§1). |
| `honor-fmbp-hwmon-dkms` | Fan RPM |
| `honor-fmbp-kbdlight-dkms` | Keyboard backlight |
| `honor-fmbp-config` | udev/hwdb: touchscreen, and the phantom `KEY_MICMUTE` inhibit |
| `honor-fmbp-hdr` | Corrected EDID so KWin can see the panel's HDR (KDE only) |
| `honor-fmbp-libfprint-sdcp` | SDCP fingerprint driver for the EgisTec ET171 |
| `honor-magicbook-pro-14` | Metapackage |

**Reboot**, then verify (§5).

> **Never hand-edit the boot entries in `/boot/limine.conf`** — they are generated by
> `limine-entry-tool` and your edits vanish on the next kernel update. (The one exception is the
> user-owned **theme block at the top**, which survives regeneration — that is what §3.2 has you
> edit for the wallpaper hash. Entries no, theme yes.) And packages must never edit
> `/etc/default/limine` — that file belongs to you. The DSDT and EDID both ride package-owned
> drop-ins in `/etc/limine-entry-tool.d/`.

---

## 5. Verify

> Two traps when checking things by hand: **`/boot` is mounted `umask=0077`**, so every read of it
> needs `sudo` — a non-root `grep`/`test`/`ls` on `/boot` fails *silently* and will mislead you.
> And `sensors` comes from the `lm_sensors` package, which may not be installed.

```sh
sudo sbctl status | grep -E 'Secure Boot|Setup Mode'      # Enabled / Disabled
sudo dmesg | grep -iE 'Table Upgrade|GINF|AE_AML'         # override applied, ZERO errors
grep -c 'BLTP7853.*Touchpad' /proc/bus/input/devices      # 1  (touchpad)
grep -c 'FTSC1000' /proc/bus/input/devices                # >0 (touchscreen)
lsmod | grep honor                                        # both DKMS modules loaded
sensors | grep -A2 honor_fmbp                             # fan1/fan2 RPM (pacman -S lm_sensors)
ls /sys/class/leds/ | grep kbd_backlight                  # huawei::kbd_backlight
cat /sys/power/mem_sleep                                  # [s2idle]  (S0ix-only hardware)
kscreen-doctor -o | grep HDR                              # "disabled", NOT "incapable"
```

The DSDT is the load-bearing one: you want `ACPI: Table Upgrade: override [DSDT- HONOR- ARL]`,
**OEM revision 3**, and **zero** `GINF`/`AE_AML` errors. A working touchpad is the visible proof.

---

## 6. Post-install

**Fingerprint** (EgisTec ET171, SDCP match-on-chip — the print lives on the sensor). Needs the
driver package (§4) plus the daemon:
```sh
sudo pacman -S --needed fprintd
fprintd-enroll && fprintd-verify      # ~15 touches to enrol
```
KDE lock-screen unlock then works with **no PAM edits** — Plasma ships a `kde-fingerprint` stack.
**The login screen does not support fingerprint**; that is an upstream gap
([plasma-login-manager issue #1](https://invent.kde.org/plasma/plasma-login-manager/-/issues/1)),
not a misconfiguration. The PAM workaround for it breaks KWallet — don't.

**HDR**: `kscreen-doctor -o | grep HDR` should say `disabled` (not `incapable`); enable it in
**System Settings → Display & Monitor**. If it still says `incapable`, `honor-fmbp-hdr` did not
apply — check `/proc/cmdline` for `drm.edid_firmware=`.

**Battery charge thresholds** — set the charge limit in **System Settings → Power Management**
(Plasma drives `huawei-wmi` natively), or from a shell:
```sh
echo '70 90' | sudo tee /sys/devices/platform/huawei-wmi/charge_control_thresholds
```
Only the OEM presets are honoured: `40 70`, `70 90`, `95 100`. The EC keeps the setting across
reboots and a full cold power-off (tested), so there is no restore service. It is **not permanent**,
though: after ~3 months unused it was found reset to `0 100` (no limit) — cause unknown; a fully
drained battery or Windows' PC Manager are the likely suspects. Check it after long breaks.

**TPM auto-unlock (optional).** If your root is LUKS-encrypted, the TPM can unlock it at boot. Seal
it **only after all Secure Boot changes are finished** — it is bound to PCR7, which measures the
Secure Boot state, so every key enrolment invalidates it. CachyOS's initramfs needs no changes:
```sh
sudo systemd-cryptenroll /dev/<luks-part> --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7
```
(Identify the partition by UUID/model — the NVMe numbers swap between boots. Your passphrase keyslot
stays as the fallback.) **Expect to run it again occasionally:** PCR7 also covers the firmware's
`dbx` revocation list, which **Windows Update** extends — after which the TPM refuses to unseal and
you get the passphrase prompt (see Troubleshooting). The same command re-seals.
**Dual-booting Ubuntu with TPM unlock?** Its seal broke when you enrolled your keys; re-seal it the
same way from Ubuntu.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| **"Boot Fail"** from the BIOS after enabling SB | `/boot/EFI/BOOT/BOOTX64.EFI` is unsigned — the firmware launches *that*, not `limine_x64.efi`. See §3.3. |
| Boot Fail **returns after a kernel/Limine update** | sbctl isn't *tracking* the files (`sbctl list-files` empty). Strip and re-sign — §3.3. |
| **"Boot Fail"** and you have been in the BIOS Secure Boot menu | The toggle **wiped your keys**. This is the known hazard. Recover via [§3.6](#36-if-it-all-goes-wrong) — two minutes, nothing is lost. |
| Limine: **`!!! CHECKSUM MISMATCH FOR CONFIG FILE !!!`** | You enrolled a config checksum and a kernel update made it stale. **Secure Boot off will NOT fix this** — the check is unconditional. Repair the ESP from another OS or live media — §3.6. Then don't enrol one — §3.2. |
| Installer shows **no internal disk** | *Not* the DSDT — the abort doesn't hide storage. Check the disk is healthy and visible in the firmware. |
| New install boots but has **no touchpad** | §2.5 was skipped, or the packages aren't in yet. Install them (§4) — or re-run `honor-fmbp-install-cachy.sh` from the installer stick against the installed root. |
| Touchpad dead after an update | `limine.conf` was regenerated and your hand-edit lost. Use the package's drop-in, never edit `limine.conf`. |
| TPM auto-unlock stopped; boot asks for the **LUKS passphrase** (journal: `TPM policy does not match current system state`) | PCR7 moved — almost always **Windows Update** adding to the firmware's `dbx`, or any Secure Boot change. Not tampering. Type the passphrase, then re-seal — §6. |
| Wifi dead after a `linux-firmware` update (`iwlwifi … Microcode SW error`, `Failed to run INIT ucode`) | Seen once, on the first boot with new firmware; a full reboot cleared it. If it persists, downgrade `linux-firmware-intel`. |
| sudo rejects a **correct** password | `pam_faillock` lockout: 3 failed attempts lock the *auth* stack for 10 min — while `passwd` still works, so it looks like sudo itself broke. `faillock --user $USER` shows it; `faillock --user $USER --reset` clears it. |
| Live system dies in the initramfs, can't find its ISO | The repack changed the volume timestamp, breaking `archisosearchuuid`. Use `remaster-cachyos-iso.sh`, which preserves it. |
| Windows/Ubuntu stop booting after enrolling keys | `--microsoft` was omitted from `enroll-keys`. Re-enter setup mode (SB off) and redo it. |
| **Installer stick won't boot** with Secure Boot on | Expected: archiso's GRUB is unsigned (no shim). Boot it with SB **off** — §2. It only ever worked with SB on via Ventoy's own MS-signed shim. |
