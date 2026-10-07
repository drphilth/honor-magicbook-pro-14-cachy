# DSDT root-cause investigation (clean fix)

> **Secure Boot note — CORRECTED.** An earlier version of this document declared "PREREQUISITE:
> Secure Boot OFF — the initrd ACPI-table override is ignored when Secure Boot is enabled". That
> is **wrong on both paths we ship**. The kernel gates the override on **lockdown**
> (`LOCKDOWN_ACPI_TABLES`), not on Secure Boot itself:
>
> - **CachyOS / Limine:** Limine boots the kernel via its own protocol, bypassing the EFI stub, so
>   lockdown never engages (`/sys/kernel/security/lockdown` = `[none]`). The override applies with
>   Secure Boot **ON** — measured on the shipping install.
> - **Ubuntu / GRUB+shim:** Secure Boot *does* put the kernel in lockdown — but since Linux v6.12,
>   an init-ordering change (the `start_kernel()` LSM static-call conversion, whose side effect
>   later became CVE-2025-1272) runs `acpi_table_upgrade()` before the lockdown LSM is armed, so
>   the override applies anyway. Observed on kernel 7.0 with SB on. This one is a quirk, not a
>   guarantee — treat SB-off as the only *promised* path on shim-based distros.
>
> For development work (bisecting DSDT variants from live media), Secure Boot off remains the
> simplest environment — that is a convenience, not a prerequisite.


We are **not** blindly applying denis-bb's patch. Goal: find the *minimal,
necessary-and-sufficient* change that restores the hardware the abort kills (framed as "primarily
USB" when this investigation started; the casualties turned out to be distro-dependent — see the
findings below), understand the mechanism, and ship a cleanly-recompiled table.

## What denis-bb's patch actually contains (analysis of his global.dsl)

| Edit | Lines | Verdict |
|---|---|---|
| OEM revision `0x02`→`0x0b` | 1 | **Required** for any override to take effect (must exceed firmware's). Not a fix in itself. |
| Remove 13× `External (..EFUN.CRFI, UnknownObj)` | 13 | **Cosmetic / toolchain collateral.** Externals are forward-decls; removed only because he excluded an SSDT during disassembly, orphaning the symbols. No hardware effect. |
| Remove `Device (NFC0)` on `\_SB.PC00.I2C1` | ~40 | **Candidate real fix #1.** But it's in a different namespace branch from the quoted `XHCI...HS03._UPC` collision — mechanism as described is a non-sequitur. Test independently. |
| Remove 4× `XHCI._PS0.PS0X` / `._PS3.PS3X` externals + their 4 calls | 8 | **Candidate real fix #2 (more plausible).** These are USB host-controller power hooks; a faulting `PS0X()` during a power transition can stop the controller enumerating. Test independently. |

Key distinction he blurs: the `AE_ALREADY_EXISTS` on `\_SB.PC00.XHCI.RHUB.HS03._UPC`
in his README is an **iasl disassembly-time** error (iasl loads DSDT+all SSDTs into
one namespace; he excludes `ssdt23` to work around it). That is **not** proven to be
the machine's **runtime** USB failure. We confirm the runtime cause from real logs.

## Procedure (on the laptop, live session)

1. **Evidence first.** Capture before changing anything:
   ```bash
   sudo dmesg | grep -iE 'acpi|AE_|dsdt|xhci|usb' | tee docs/dmesg-stock.txt
   journalctl -k -b | grep -iE 'acpi|AE_' | tee -a docs/dmesg-stock.txt
   sudo acpidump -b           # DSDT + ALL SSDTs *and MSDM* -> dsdt/original/
   # ⚠️ acpidump -b also dumps MSDM = the machine's Windows OEM product key.
   #    dsdt/original/ (and any MSDM* file) is .gitignored — never commit raw dumps.
   ```
   Identify the *actual* runtime error and which controllers fail to enumerate.

2. **Clean decompile (delete nothing).**
   ```bash
   iasl -e ssdt*.dat -d dsdt.dat          # full context so externals resolve
   ```
   If this errors with AE_ALREADY_EXISTS, that localizes a duplicate:
   `grep -l 'HS03._UPC' ssdt*.dsl` → note which SSDT redefines it. Decide whether the
   duplicate is real (also breaks at runtime) or an iasl-only artifact.

3. **Bisect the candidates.** Build one variant per hypothesis, load it via the initrd
   override (an uncompressed cpio containing `kernel/firmware/acpi/dsdt.aml`, prepended
   to the initramfs), reboot, verify from dmesg:
   - V1: remove **only** `Device (NFC0)` (+ OEM bump).
   - V2: remove **only** the `PS0X`/`PS3X` externals+calls (+ OEM bump).
   - V3: whichever combination the evidence points to.
   Record which variant actually restores USB/NVMe. Ship the minimal one.

4. **Prefer an SSDT-targeted override** if the real culprit is a duplicate/bad object
   in a single small SSDT — override just that table instead of the whole 528 KB DSDT.

5. **Recompile clean.** Aim for zero errors and minimal warnings, full `-e` context,
   no gratuitous external deletions. Bump OEM revision. Validate with `acpiexec`.

6. **Document the mechanism** below, and diff the final result against denis-bb's to
   explain every divergence.

## Findings (from recon 2026-06-30, Fedora 44, kernel 6.19.10)

The real failure is NOT `AE_ALREADY_EXISTS` (that was denis-bb's *disassembly-time*
artifact). The actual runtime chain:

```
ACPI Error: No pointer back to namespace node in package ... resolving operands for [Index]
ACPI Error: Aborting method \_SB.GINF ... (AE_AML_INTERNAL)
ACPI Error: Aborting method \_SB.GNUM ... (AE_AML_INTERNAL)
ACPI Error: AE_AML_INTERNAL, [DSDT] table load failed          <-- ROOT
ACPI BIOS Error: Could not resolve symbol [\_SB.PR00] / [\_SB.PC00.GFX0] /
                 [\_SB.PC00] / [\_SB.PC00.TCPU] / UsbCTabl ...  <-- cascade
```

- **Root cause:** `\_SB.GINF` is malformed (bad package/`Index`). It runs *during DSDT
  load* via `\_SB.GNUM`, triggered by `NFC0`'s body (`INT1 = GNUM(0x0014080A)`). The
  load **aborts partway**, leaving half the namespace unbuilt → the flood of
  "could not resolve symbol" errors, a failed USB-C SSDT, and **no touchpad node**.
- **USB + NVMe still work** on Fedora 6.19 (they don't depend on the missing nodes) —
  so the Debian/Ubuntu "no USB controllers" symptom does **not** bite here. The only
  user-visible breakage from this is the **touchpad** (its ACPI/i2c-hid node never
  gets created — zero touchpad/i2c-hid lines in dmesg).
- **DISTRO-specific severity, NOT a kernel-version effect.** On Ubuntu 26.04 the same abort
  is far worse: the installer sees **no disks at all** — neither USB nor NVMe — so the fix
  genuinely *is* **boot-critical there** (hence the pre-first-boot initramfs bake). But that
  does **not** generalise:

  | Distro / kernel | stock DSDT, no override |
  |---|---|
  | **Ubuntu 26.04** | sees **nothing** — no USB, no NVMe. Cause still UNKNOWN. |
  | Fedora 6.19 | USB + NVMe fine |
  | **CachyOS, kernel 7.1.3** | USB + NVMe fine (disks *and* partitions); only touchpad + touchscreen die — **measured 2026-07-12**, booting with the override removed |

  So this is **not** a "kernel >= 7.0 makes it worse" effect, as an earlier version of this doc
  implied: CachyOS on 7.1.3 is newer than Ubuntu's 7.0 and is *fine*. Two distros survive the
  abort, one does not. Whatever blinds Ubuntu is an unexplained Ubuntu-specific issue we
  deliberately did **not** chase. **Do not call the DSDT "boot-critical" outside Ubuntu.**
  Takeaway: the NFC0/GNUM fix restores the *whole* namespace; which casualties are user-visible
  depends on the distro, so the "touchpad" shorthand is the honest scope everywhere except Ubuntu.
- This makes **NFC0 removal candidate #1, confirmed**: it stops the broken GNUM/GINF
  from executing at load. `EFUN.CRFI` / `PS0X` edits are confirmed disassembly collateral.

| Item | Result |
|---|---|
| Real runtime error | `AE_AML_INTERNAL` in `\_SB.GINF` → `[DSDT] table load failed` |
| Trigger (load-time) | `NFC0` body runs `GNUM(0x0014080A)` → `GINF` |
| USB / NVMe | **work** on stock Fedora 6.19 (no DSDT patch) |
| Touchpad | **broken** — node missing because DSDT load aborts |
| BIOS / DSDT match | BIOS 1.13; DSDT 528211 bytes = denis-bb reference exactly |
| Minimal fix | delete 2 lines in `NFC0`: `CreateWordField (SBGF, 0x17, INT1)` + `INT1 = GNUM (0x0014080A)`; bump DSDT OEM rev `0x02`→`0x03` |
| Approach | whole-DSDT override via initrd (works with Secure Boot on or off — see the note at the top) |

### The 2-line fix (confirmed)

`NFC0` (the only call in the whole DSDT with a literal arg, at device-body =
load-time scope) runs `GNUM(0x0014080A)` → `GINF` → `GDSC` before its data is valid →
`AE_AML_INTERNAL` → DSDT load aborts. Deleting those two lines stops the load-time
call; `GINF`/`GNUM` stay intact for runtime. Net diff from stock DSDT = **2 lines + OEM bump**.

### denis-bb's other 17 edits = toolchain artifacts, NOT fixes (now fully explained)

Recompiling the patched `.dsl` with the **2020-era iasl** on the WSL desktop throws 17
`Error 6163 "Object is created temporarily in another method"`:
- **13× `EFUN.CRFI` externals** — *dangling* (declared, never referenced in the DSDT). Vestigial.
- **4× `XHCI._PS0.PS0X` / `._PS3.PS3X` externals** — used in guarded `If (CondRefOf(PS0X)) { PS0X() }`
  optional SSDT power hooks. Valid AML; the stock firmware runs them.

These are legal constructs the **old iasl can't re-emit**; denis-bb deleted them only to
make his recompile succeed.

### RESOLVED — they are unavoidable for ANY standalone DSDT override (proven)

Tested with iasl 20200925, iasl 20260408, and `-e` (SSDT context): all fail the same way.
Root reason: `SSDT23` (`xh_mtlp4`) redefines `HS03._UPC`, so it cannot be co-loaded for
disassembly — and it (plus the absence of any `XHCI.PS0X` definition) means these refs
point at objects no standalone DSDT can express. From first principles:
- **13 `EFUN.CRFI`** — declared, never referenced anywhere → dead, delete.
- **4 `XHCI._PS0/_PS3.PS0X/PS3X`** — *no loaded table defines `PS0X`/`PS3X` under XHCI*
  (SSDT20 defines them only under I2C/touchpad scopes). The `If(CondRefOf(PS0X))` guards
  are therefore always false at runtime → dead hooks. Delete the 4 externals + their 4
  guarded blocks.

### FINAL fix (built & verified, OEM rev 0x03; 522901-byte AML as shipped)

`dsdt/build.sh` (run with a current iasl) produces `dsdt/patched/dsdt.aml`. Whole diff
vs stock = `dsdt/patched/clean-fix.patch`:
| Edit | Lines | Why |
|---|---|---|
| `NFC0`: drop `CreateWordField(SBGF…)` + `INT1 = GNUM(0x0014080A)` | 2 | **THE FIX** — stops the load-time GINF crash; device kept |
| OEM rev `0x02`→`0x03` | 1 | required so the initrd override is accepted |
| 13× `EFUN.CRFI` externals | 13 | dead decls; standalone-compile requirement |
| 4× `XHCI._PS0/_PS3` externals + 4 guarded blocks | ~20 | dead hooks; standalone-compile requirement |
| Touchscreen: inject `PowerResource (PWRR)` + `_PR0`/`_PR3` on `I2C2.TPL1` | ~40 | powers the FTSC1000 panel at i2c-hid probe (added after this section was first written — it, not the GNUM fix, is why the shipped AML is larger than the 522642 bytes originally recorded here; see `dsdt/inject-touchscreen-power.py`) |

### vs denis-bb (independent convergence)

Same *necessary* removals (validates both), but ours is cleaner: we keep the `NFC0`
device (2-line surgical fix vs his whole-device delete) and drop the dead `If` blocks
(vs his empty `If(CondRefOf){}` shells). And we know the true mechanism — the load-time
`GINF` abort — which his README misattributes to NFC/`AE_ALREADY_EXISTS`.

Loaded via `dsdt/patched/acpi_override.img` (cpio: `kernel/firmware/acpi/dsdt.aml`)
prepended to the initramfs.

### VALIDATED on the laptop (manual GRUB `e`-edit, grub2 mode)

Added before the `linux` line: `insmod exfat; search --set=mbdev --file /dsdt.aml;
acpi ($mbdev)/dsdt.aml`. Result: **touchpad works**, `verify.sh` reports DSDT OEM
revision **3** (our table is live), GINF/load-failure lines **0**. GRUB's `acpi`
command works on this UEFI → the remaster can use a simple `acpi /dsdt.aml` in the
ISO's grub.cfg. (Ventoy's `conf_replace` plugin is NOT honored on this firmware —
tested and abandoned; the remaster script edits the ISO's own grub.cfg instead.)

### Post-fix ACPI error survey (7 benign "could not resolve symbol", down from dozens)

Nothing harmful was unmasked. The DSDT now loads fully; residual not-founds are the
firmware's "optional device absent" pattern:
- `TXHC.RHUB.SS01`–`SS04` (×4): Thunderbolt/USB4 SuperSpeed port power-mgmt refs to
  ports not enumerated. Harmless.
- `I2C3.TPD0`, `I2C4.TPL1`, `I2C5.TPL1` (×3): touchpad power code probing the I2C buses
  the touchpad is NOT on (it works on its actual bus). Harmless.
No `AE_AML_INTERNAL`, no load failure, no silently-broken feature. Could be silenced
with more DSDT edits but not worth it — standard laptop dmesg noise.
