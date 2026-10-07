# Secure Boot key-wipe repro protocol (2026-07-12)

> **START HERE — the investigation is closed. Read §C (architecture) then §E (checksum policy).**
>
> - Ship **sbctl + Limine**, `sbctl enroll-keys --microsoft --firmware-builtin`. (§C)
> - **shim + MOK was tried and RETRACTED** — a category error with Limine; it bricked the machine. (§C)
> - The **BIOS Secure Boot toggle destroys the keys** (H-toggle, confirmed at A4, n=3). A documented
>   hazard with a two-minute recovery — not a reason to change bootloader.
> - The **Limine config checksum** is safe *iff* the firmware boots Limine **by path**; on the
>   removable fallback it goes stale and panics **unrecoverably** (SB-off does NOT help). Always keep
>   `EFI/BOOT/BOOTX64.EFI` signed but **checksum-free** — it is the rescue binary. (§E supersedes §D)
>
> Sections A/B are the key-wipe evidence trail; §D is superseded by §E.

## Context

On 2026-07-12 the sbctl custom keys (`Platform Key`/`Key Exchange Key`/`Database Key`) were
factory-reset (back to `FermatB_PK` + Microsoft certs) → CachyOS/Limine Boot Fail. Forensics
(Windows measured-boot TCG logs, System.evtx, PPI sysfs) proved the keys were still **ours and
enforcing** at the day's only Windows boot (17:01 BST), and factory two reboots later. Two suspects
remain in that window, and this protocol separates them:

- **H-Windows**: the Windows Hello/TPM-repair flow (firmware-executed PPI TPM clear at the next
  reboot) also factory-resets the Secure Boot key store.
- **H-toggle**: a plain BIOS SB off→on cycle (with custom keys enrolled, nothing written during the
  off-window) factory-resets the store. This was never tested in isolation — the only such toggle
  ever performed happened right after the Windows TPM clear.

**Note to the CachyOS-side Claude session: your local sitrep memory (v1) is superseded — v1's
"toggle restores factory keys" verdict and v2's "toggles proven safe" were both overclaims. This doc
is current. Update local memory from it.**

## Ground rules

- Record every checkpoint in the RESULTS section below (append, commit, push — git is the
  cross-OS channel).
- Identify disks by model, never by `nvmeXn1` (numbering swaps): FORESEE = CachyOS (USB),
  Samsung 970 EVO = Ubuntu, KIOXIA = Windows.
- Any unexpected Boot Fail: recover with SB off → boot CachyOS → `sudo sbctl enroll-keys
  --microsoft` → SB on. Keys persist at `/var/lib/sbctl/keys`; on-disk Limine signatures stay valid.
- Don't boot Windows before Test A is complete — it can contaminate the toggle test.

## Key-state reading (run as root on CachyOS at every checkpoint)

```sh
od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
od -An -t u1 /sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c
efi-readvar -v PK  2>&1 | grep -E 'CN=|Variable|no entries'
efi-readvar -v KEK 2>&1 | grep -E 'CN=|Variable|no entries'
efi-readvar -v db  2>&1 | grep -E 'CN=|Variable|no entries'
sbctl status
cat /sys/class/tpm/tpm0/ppi/response   # "5 0: Success" is stale residue from the incident
```

## Protocol

### A0 — SB off, BEFORE re-enrolling (bonus discriminator)
Reboot → BIOS → SB **off** → boot CachyOS → read state.
Store currently holds FACTORY keys. So:
- `PK = FermatB_PK` visible ⇒ Setup Mode does NOT blank the presentation of a populated store ⇒
  the incident's empty reads meant the store was genuinely EMPTY at those moments (big clue).
- `PK` empty ⇒ SB-off hides/clears presentation regardless ⇒ empty reads were uninformative
  (as currently assumed).

### A1 — re-enroll (still SB off)
```sh
sudo sbctl enroll-keys --microsoft
```
Read state immediately. Expect: `SetupMode=0` (PK write exits Setup Mode even with SB off),
`PK = Platform Key`, `db` contains `Database Key` + Microsoft certs.

### A2 — SB on, verify baseline
Reboot → BIOS → SB **on** → CachyOS should boot. Read state.
Expect: `SecureBoot=1`, our keys. (Boot Fail here = something new; recover and stop.)

### A3 — SB off, observe
Reboot → BIOS → SB **off** → boot CachyOS → read state. Record PK/db presentation
(empty vs `Platform Key`) — with A0 this pins down the Setup-Mode semantics.
Do NOT run any sbctl write commands in this boot.

### A4 — SB on, TEST A VERDICT
Reboot → BIOS → SB **on** → boot CachyOS.
- **Boots, keys ours** ⇒ plain toggles are SAFE. H-toggle dead. Proceed to B.
- **Boot Fail** ⇒ **H-toggle CONFIRMED** (verify from an SB-off boot: expect factory keys).
  Windows exonerated for the wipe mechanism (its TPM clear remains a separate PCR7 nuisance).
  Recover, skip Test B, write up.

### B1 — Windows exposure (only if A4 passed)
Reboot → Windows (SB on). Let Windows Hello do whatever it wants (PIN repair etc. — note every
prompt). Stay logged in a few minutes. Reboot.

### B2 — TEST B VERDICT
Boot CachyOS (SB on).
- **Boot Fail** ⇒ **H-Windows CONFIRMED**: Windows TPM maintenance factory-resets the SB keys.
  Verify keys factory from an SB-off boot, recover, write up.
- **Boots, keys ours** ⇒ neither reproduced this pass. Likely the wipe needs the TPM-clear flow
  specifically and Hello didn't re-clear this time (PCR7 changed again at A1, so it might). Optional
  B3: in Windows Security → Security processor → "Clear TPM", then retry B2. Record either way.

### B3 forensics (optional, after any B verdict)
From CachyOS, mount the KIOXIA NTFS partition read-only:
- `C:\Windows\System32\winevt\Logs\System.evtx` (`evtxexport`): fresh TPM-WMI event 519 = new clear.
- Newest `C:\Windows\Logs\MeasuredBoot\*.log` (`tpm2_eventlog` or `strings`): which keys the
  firmware measured at the B1 Windows boot.

## RESULTS (append below, one block per checkpoint)

<!--
### <checkpoint> — <date time>
SecureBoot=  SetupMode=
PK:
KEK:
db:
sbctl status:
notes:
-->

### A0 — SB off, before re-enrolling — 2026-07-12 (CachyOS session)
SecureBoot=0  SetupMode=1
PK:  Variable PK has no entries
KEK: Variable KEK has no entries
db:  Variable db has no entries
sbctl status: Setup Mode: Enabled | Secure Boot: Disabled | Vendor Keys: none
ppi/response: `5 0: Success`   ppi/request: 0

**VERDICT — A0 discriminator resolves to the SECOND branch.** The store is known (from the Ubuntu
forensics) to hold FACTORY keys right now, yet PK/KEK/db all present as EMPTY with SB off.
⇒ **Setup Mode blanks the PRESENTATION of a populated store.** Therefore the incident's empty reads
were **UNINFORMATIVE** — they did not mean the store was empty, and must not be used as evidence.
(The CachyOS session had earlier treated an empty SB-off read as meaningful. It is not.)

Corollary: **you cannot audit the key store with SB off.** Every key reading must be taken with
Secure Boot ON.

`ppi/response: 5 0: Success` = the firmware executed PPI opcode 5 (**Clear TPM**) successfully —
the residue of the Windows Hello PIN-repair flow. Consistent with H-Windows; not yet proof.

### A1 — re-enroll (still SB off) — 2026-07-12 (CachyOS session)
`sudo sbctl enroll-keys --microsoft` → "Enrolled keys to the EFI variables!"
SecureBoot=0  SetupMode=**0**
PK:  CN=Platform Key                     (ours)
db:  CN=Database Key (ours) + Microsoft Corporation UEFI CA 2011, Windows Production PCA 2011,
     UEFI CA 2023, Option ROM UEFI CA 2023, Windows UEFI CA 2023, + roots
sbctl status: Setup Mode: Disabled | Secure Boot: Disabled | Vendor Keys: microsoft

**Refines A0.** SetupMode went 1 → 0 on the PK write, *with Secure Boot still OFF* — and the store is
now fully READABLE with SB off. So A0's corollary ("cannot audit with SB off") is **too strong**. The
correct rule:

> **The key store presents as EMPTY when `SetupMode=1` (i.e. no PK), NOT merely when SB is off.**
> With a PK present you can read PK/KEK/db perfectly well with Secure Boot disabled.

The open question is therefore sharper than "does SB-off hide things": before A1 the store held
FACTORY keys yet `SetupMode=1` and PK read empty — meaning **turning SB off had left no active PK**.
A2 tests what turning SB back ON does to the PK we just wrote.

**NEXT: A2** — reboot → BIOS → SB **on** → boot CachyOS → read state.
This is now a CLEAN, isolated test of H-toggle: our keys were just enrolled, nothing else has touched
the machine, and Windows has NOT been booted in this window.

### A1.5 — plain reboot, NO BIOS entry, no SB toggle — 2026-07-12 18:04 (CachyOS)
SecureBoot=**1**  SetupMode=0     ← SB came back ON with no BIOS interaction whatsoever
PK:  CN=Platform Key                      (ours)
KEK: CN=Key Exchange Key (ours) + Microsoft KEK CA 2011 / KEK 2K CA 2023
db:  CN=Database Key (ours) + all 8 Microsoft certs
sbctl status: Setup Mode: Disabled | Secure Boot: Enabled | Vendor Keys: microsoft
CachyOS booted normally under SB. ppi/response still `5 0: Success` (stale residue).

**MAJOR: this pins down the firmware's semantics.**

> **The BIOS "Secure Boot: Disabled" setting on this machine is NOT a separate enforcement flag —
> it behaves as "clear the PK / enter Setup Mode". Enrolling a PK exits Setup Mode and enforcement
> returns BY ITSELF on the next boot, with no BIOS visit.**

This one model explains every previous oddity:
- "SB off" always showed `SetupMode=1` **and** empty PK/db — because there genuinely was no active PK.
- Writing a PK at A1 flipped SetupMode 1→0 *while SB was still nominally "off"* — we had just undone
  the "disabled" state.
- No BIOS trip was needed to re-enable SB.

**Implication for H-toggle (raises its prior):** if "disable SB" *clears the PK*, then toggling SB off
with custom keys enrolled would DESTROY them, and enabling SB again must re-provision something —
factory keys. That is precisely the observed Boot Fail.

**A1.5 does NOT test H-toggle** (no BIOS toggle happened). It is a clean CONTROL, and it establishes:
**custom keys survive a plain reboot.**

**NEXT: A3/A4 remain the real H-toggle test** — enter the BIOS, SB **off**, boot, read; then BIOS,
SB **on**, boot, read. Windows must NOT be booted in that window.

---

## The decision this protocol actually settles

The real question is not academic: **can sbctl custom keys coexist with Windows 11 on this machine?**
A4 answers it.

| A4 outcome | Cause of the wipe | sbctl + Win11 verdict |
|---|---|---|
| **Boot Fail** | **H-toggle** — the BIOS SB toggle clears the PK | **Coexistence OK.** Never touch the BIOS SB toggle once custom keys are enrolled. Recovery never needs the firmware anyway (see below). Windows exonerated. |
| **Boots, keys ours** | **H-Windows** — the PPI TPM clear (Hello/PIN repair, TPM maintenance, some Windows Updates) | **Coexistence NOT viable.** Any Windows TPM operation would silently wipe the SB keys and Boot-Fail CachyOS. Switch to **shim + MOK**. |

### Fallback if H-Windows wins: shim + MOK

- `shim` is Microsoft-signed → the **factory `db` is never modified**, so there is nothing for a TPM
  clear / key reset to destroy.
- Our signing key lives in **`MokList`**, a separate EFI variable.
- **Already evidenced on this machine:** the **Canonical and Ventoy MOKs survived the entire incident**
  — the TPM clear, the key wipe, everything. `db` was reset to factory while `MokList` was untouched.

### Recovery (better than the runbook's — no BIOS trip needed)

Established at A1/A1.5: **enrolling a PK exits Setup Mode and re-arms Secure Boot by itself.**
```sh
# BIOS: SB off (only needed to get into Setup Mode) → boot CachyOS →
sudo sbctl enroll-keys --microsoft
# reboot — Secure Boot comes back ON automatically, with our keys. No BIOS visit.
```
Keys persist at `/var/lib/sbctl/keys`; the on-disk Limine/BOOTX64 signatures stay valid throughout.

### A3 — BIOS SB toggled OFF, booted CachyOS, NO sbctl writes — 2026-07-12 18:17
SecureBoot=0  SetupMode=1
PK:  no entries
KEK: no entries
db:  no entries
sbctl status: Setup Mode: Enabled | Secure Boot: Disabled | Vendor Keys: none
ppi/response: `5 0: Success` (stale)

Consistent with the A1.5 model (BIOS "SB off" ⇒ clear the PK ⇒ Setup Mode). **But per A0 this empty
read is UNINFORMATIVE** about whether our keys still exist underneath — Setup Mode blanks the
presentation of a populated store. It cannot distinguish "keys destroyed" from "keys suspended".

**A4 is the discriminator.**

### A4 — BIOS SB toggled back ON — 2026-07-12 — ★ VERDICT ★
**BOOT FAIL.** CachyOS/Limine rejected.

## ★ H-TOGGLE CONFIRMED ★

A plain BIOS Secure Boot **off → on** cycle, with custom keys enrolled and **nothing else touched**
(no Windows boot, no sbctl writes, no TPM operation in the window), is **SUFFICIENT** to destroy the
sbctl custom keys and Boot-Fail the system.

This reproduces the original incident **without Windows**. The firmware's "Secure Boot: Disabled"
setting clears the PK (→ Setup Mode); re-enabling it re-provisions a key store our `Database Key` is
not in, so our correctly-signed Limine is rejected.

### ⚠️ THE RULE
> **Once sbctl custom keys are enrolled on this machine, NEVER use the BIOS Secure Boot toggle.**
> It silently destroys them. And you never need it: `sbctl enroll-keys` exits Setup Mode and
> **re-arms Secure Boot by itself** (proven at A1.5). The only legitimate use of the BIOS toggle is
> to *get into* Setup Mode when you have no keys to enrol.

### ⚠️ WHAT THIS DOES **NOT** PROVE
A4 shows H-toggle is **SUFFICIENT**. It does **NOT** show H-Windows is false. The original incident
had *both* a Windows TPM clear *and* an SB toggle in the window; we have now proved the toggle alone
explains it, but Windows may **also** wipe the keys. **The coexistence question is therefore still
OPEN** — Test B (boot Windows, touch NO BIOS setting, reboot, check) is still required to answer
"can sbctl coexist with Win11 on this machine?"

Do not record "Windows is exonerated". It is merely *no longer necessary* as an explanation.

### Protocol correction
The original protocol said "Boot Fail ⇒ verify from an SB-off boot: expect factory keys". **That step
is INVALID** — A0 established that an SB-off boot is in Setup Mode and reads PK/KEK/db as EMPTY
regardless of the store's contents. Verification MUST be done with **Secure Boot ON**, from an OS that
still boots under it (Ubuntu, via Microsoft-signed shim).

### A4 post-mortem — key store read UNDER ENFORCEMENT — 2026-07-12 evening (Ubuntu, via MS shim)
SecureBoot=**1**  SetupMode=0
PK:  CN=FermatB_PK (factory ×2)                    — our `Platform Key` DESTROYED
KEK: Microsoft only (KEK CA 2011, KEK 2K CA 2023, 3rd-Party Root, RSA Devices Root 2021)
                                                   — our `Key Exchange Key` DESTROYED
db:  CN=FermatB_DB ×2 + the 8 Microsoft certs      — our `Database Key` DESTROYED
MOKs: **ALL SURVIVED** — Canonical, Ventoy, magicbook-ubuntu DKMS keys, all still enrolled.

**Confirms the A4 mechanism end-to-end:** re-enabling SB after the PK-clearing "off" state
re-provisions the FACTORY key store (identical set to the original incident's), which our
`Database Key` is not in ⇒ correctly-signed Limine rejected ⇒ Boot Fail.

**MOK survival is now proven across TWO wipes** (the original incident incl. a TPM clear, and the
pure A3/A4 toggle wipe). `MokList` is untouched by whatever re-provisions `PK`/`KEK`/`db`.
⇒ **shim + MOK is immune to this entire failure mode** — strongest evidence yet for it as the
shipping architecture for the public Cachy port if Test B goes badly (or even if it doesn't).

**STATE: CachyOS is currently Boot-Failed. NEXT STEPS:**
1. Recover: BIOS → SB off → boot CachyOS → `sudo sbctl enroll-keys --microsoft` → reboot
   (SB re-arms itself per A1.5 — do NOT touch the BIOS toggle again).
2. **Test B** (the still-open Win11-coexistence question): with keys freshly enrolled and SB
   enforcing, boot Windows → touch NO BIOS setting → let Hello/TPM do whatever it wants → reboot →
   does CachyOS still boot? Then read keys (from CachyOS if it boots, from Ubuntu if it doesn't).

### RECOVERY after A4 — 2026-07-12 evening (CachyOS, SetupMode=1)
`sudo sbctl enroll-keys --microsoft` → enrolled.
SecureBoot=0 (pre-reboot)  SetupMode=**0**
PK: CN=Platform Key (ours) · db: our Database Key + 10 Microsoft cert lines
limine_x64.efi and /EFI/BOOT/BOOTX64.EFI both still signed `CN=Database Key` — on-disk signatures
survive a firmware key wipe untouched, as expected. **No BIOS visit used or needed.**

---

## TEST B — the Win11 coexistence question

**Pre-conditions (all true right now):** custom keys freshly enrolled; SB will re-arm itself on the
next boot; **the BIOS toggle must NOT be touched at any point in this test** — that is the whole point
(A4 already proved the toggle wipes keys; B isolates *Windows*).

Note the test is well-primed: we just re-enrolled keys, so **PCR7 has moved again**. Windows Hello is
therefore likely to demand another PIN repair — which is exactly the flow that schedules the PPI TPM
clear (`ppi/response` still shows the last one: `5 0: Success`). If H-Windows is real, this should fire.

### B0 — baseline
Reboot (no BIOS). CachyOS should boot with SB on and our keys. Read state. *(If this Boot-Fails,
something is wrong beyond our models — stop and re-diagnose.)*

### B1 — Windows exposure
F12 → **Windows**. Touch **no** BIOS setting. Let Hello/TPM do whatever it wants — **record every
prompt** (PIN reset? BitLocker? TPM warning?). Stay logged in a few minutes. Reboot.

### B2 — VERDICT
Boot **CachyOS**.
- **Boots, keys ours** ⇒ **Windows is innocent.** H-Windows dead. The original incident was the toggle
  all along. sbctl+Win11 *can* coexist — subject to the never-touch-the-toggle rule.
- **Boot Fail** ⇒ **H-WINDOWS CONFIRMED.** Windows TPM maintenance wipes the SB key store. sbctl is
  then doubly unviable here. (Read the store from Ubuntu under enforcement, as in the A4 post-mortem.)

**Either way the shipping architecture is already decided** — see below. B is a completeness test, not
a decision test.

---

## ARCHITECTURE VERDICT (independent of Test B)

**sbctl custom keys are NOT shippable on this machine, even if Windows turns out to be innocent.**

A4 proved that a plain **BIOS Secure Boot toggle destroys the keys**. The resulting safety rule —
*"never touch the BIOS SB toggle, ever, or the machine stops booting"* — is not a rule you can hand to
strangers. People toggle SB to boot a live USB, to test something, because a forum said so.

**shim + MOK is structurally immune**, and that is now *observed*, not theorised:

> **`MokList` survived TWO independent firmware key wipes on this machine** — the original incident
> (which included a TPM clear) and the clean A3/A4 toggle. Canonical, Ventoy and the magicbook-ubuntu
> DKMS keys are all still enrolled, while `PK`/`KEK`/`db` were reset to factory both times.

shim never puts anything in the firmware key store: it is Microsoft-signed (so the factory `db` already
trusts it) and our key lives in `MokList`, which nothing here touches.

**The honest cost:** shim does not cooperate with **Limine** (Limine boots the kernel via its own
protocol, bypassing the EFI verification that shim exists to perform). Adopting shim+MOK likely means
moving to **systemd-boot** or **GRUB** — which also means reworking the DSDT mechanism, since our
`limine-entry-tool` drop-in is Limine-specific. That rework is the price of a Secure Boot story without
a landmine in it.

### B0 — baseline before Windows exposure — 2026-07-12 22:47 (CachyOS)
SecureBoot=**1**  SetupMode=0   ← re-armed ITSELF after the enrol; no BIOS visit (re-confirms A1.5)
PK: CN=Platform Key (ours) · db: our Database Key + 10 Microsoft cert lines
sbctl: Setup Mode: Disabled | Secure Boot: Enabled | Vendor Keys: microsoft
Health: 0 ACPI errors, touchpad present, both DKMS modules loaded.
**ppi/request = 0** — nothing pending. Clean slate: anything that appears is attributable to Windows.

**B1 now: F12 → Windows. No BIOS setting touched. Record every prompt. Reboot. Then B2 → CachyOS.**

### Note: Test B no longer decides the architecture

Reasoned through with the user before running it:

- **Windows wipes the keys** ⇒ sbctl definitively dead here. Recovery would be needed after *every
  Windows boot* (BIOS → SB off → boot → enrol → reboot). Not "unfixable", but nobody will live with it.
- **Windows innocent** ⇒ sbctl is still only a gray zone: "works, provided you never touch a BIOS
  switch that exists to be touched". Not a shippable rule.

Either branch lands on **shim + MOK**. And the one thing B *could* have changed — "does Windows also
nuke `MokList`?" — is **already answered**: the original incident **included a TPM clear**, and the MOKs
survived it.

**Why shim+MOK is immune to BOTH failure modes (observed, not theorised):**

| | firmware wipe does… | shim + MOK |
|---|---|---|
| shim itself | `PK`/`KEK`/`db` re-provisioned to **factory** | shim is **Microsoft-signed** and the MS certs *are the factory db* — a factory re-provision **restores exactly what shim needs**. It cannot be orphaned. |
| our signing key | custom `db` entries destroyed | lives in **`MokList`** — **survived both wipes** (TPM-clear incident *and* the clean A3/A4 toggle). |

⇒ Under shim+MOK, an SB toggle or a Windows TPM clear leaves the machine **still booting**, because we
never put anything in the firmware key store at all.

**Test B is therefore a COMPLETENESS test** — run to close the file with full evidence, not to choose
the architecture. The architecture is decided.

### B1/B2 — Windows exposure — 2026-07-12 ~22:5x — ★ VERDICT ★
**B1:** booted Windows 11 under SB with our keys enrolled. **PIN login worked normally — no Windows
Hello repair, no BitLocker prompt, no TPM warning.** No BIOS setting touched. Rebooted.
**B2:** **CachyOS BOOTED**, Secure Boot enforcing, keys intact:
SecureBoot=1  SetupMode=0 · PK=`CN=Platform Key` (ours) · db = our `Database Key` + 10 MS certs
**ppi/request = 0** — Windows scheduled **no** TPM operation. `ppi/response` unchanged (stale
`5 0: Success` from the original incident).
Health: 0 ACPI errors, touchpad, both DKMS modules.

## ★ H-WINDOWS NOT REPRODUCED ★

A normal Windows 11 boot — Hello working, no TPM operation — **does not disturb the Secure Boot key
store**. Combined with A4, the picture is complete:

| Hypothesis | Status |
|---|---|
| **H-toggle** | ✅ **CONFIRMED** (A4). A BIOS SB off→on cycle wipes custom keys and re-provisions the factory store. **This alone fully explains the original incident — Windows was never needed.** |
| **H-Windows** | ❌ **NOT REPRODUCED** (B2). Normal Windows use is harmless to the keys. |

### The earlier PIN reset — causality was BACKWARDS from my assumption
I assumed *enrolling keys → PCR7 changed → Hello broke → PIN reset → PPI TPM clear*. **Wrong.** We
changed PCR7 again with this re-enrolment and **Hello was fine**. So a PCR7 change alone does *not*
break Hello. The earlier PIN reset was caused by **the TPM clear itself** (which destroys the sealed
key material). The chain ran: *something cleared the TPM → Hello broke → PIN reset*, not the reverse.

### STILL UNKNOWN (do not paper over)
Whether a Windows-**initiated TPM clear** would wipe the SB key store. Windows performed none this
pass, so that path is untested. It could still arise from a Windows reset, a TPM firmware update, or a
manual "Clear TPM" (optional test B3). **It cannot change the architecture:** a TPM clear demonstrably
does *not* touch `MokList` (the MOKs survived the original incident, which included one), so shim+MOK
is immune either way.

---

# FINAL ANSWER: can sbctl custom keys coexist with Windows 11 here?

> ### ⚠️ THE ARCHITECTURE VERDICT IN THIS SECTION IS SUPERSEDED — see [§C](#c-shim--mok--tested-broke-the-machine-abandoned-2026-07-13).
> The **evidence** below stands (H-toggle confirmed, H-Windows not reproduced, MOKs survive). The
> **decision** drawn from it — "ship shim + MOK" — was acted on, **bricked both boot paths**, and is
> **retracted**. The shipping answer is **sbctl + Limine**, the path CachyOS documents.
> Do not reintroduce shim without reading §C first.

**In practice: yes-ish. As a shippable product: NO.**

**Windows is not the problem. The BIOS Secure Boot toggle is.** A single flip of a switch that exists
specifically to be flipped — to boot a live USB, to try something, because a forum said so — silently
destroys the keys and leaves an unbootable system. *"Never touch the Secure Boot switch"* is not a rule
you can hand to strangers.

**DECISION: ship shim + MOK for the public CachyOS port.** It puts **nothing** in the firmware key
store, so there is nothing for a toggle (or a TPM clear, or anything else that re-provisions PK/KEK/db)
to destroy:
- **shim is Microsoft-signed**, and the Microsoft certs *are* the factory db — a factory re-provision
  restores precisely what shim needs.
- **our signing key lives in `MokList`** — observed to survive **both** wipes on this machine.

**Honest cost:** shim does not cooperate with **Limine** (Limine boots the kernel via its own protocol,
bypassing the EFI verification shim exists to perform), so this likely means **systemd-boot or GRUB**,
and reworking the Limine-specific DSDT drop-in with it. Scoping next.
### shim+MOK attempt post-mortem + ESP repair — 2026-07-13 (Ubuntu session)

**Symptom:** CachyOS unbootable in BOTH modes. SB: shim blue screen `Verification failed: (0x03)
Unsupported`. Non-SB: `Section 0 is inside image headers / Malformed section header /
start_image() returned Unsupported` → BOOT FAIL.

**Root cause (read from the ESP + the CachyOS session transcript):** the 2026-07-12 23:21 SBAT
injection used `objcopy --add-section .sbat=...` **without setting a section address** — objcopy
placed `.sbat` at **VMA 0**, i.e. inside the PE headers. shim's strict PE loader rejects the image
in both modes (in non-SB it still parses the PE even though it skips signature checks). The MOK
enrolment itself and the shim/mmx64 copies were all fine.

**Repair performed (from Ubuntu, ESP mounted rw):**
1. `EFI/BOOT/BOOTX64.EFI` restored from the session's own backup `BOOTX64.EFI.sbctl-limine.bak`
   (valid Limine, `CN=Database Key` signature, clean section layout) → **boots in non-SB mode now**.
2. shim experiment preserved in `EFI/shim-staging/` (shimx64.efi, mmx64.efi, the malformed
   grubx64, README.txt with retry instructions).
3. **Correctly-built** candidate staged: `grubx64.efi.FIXED-sbat-untested` — same SBAT CSV, but
   `.sbat` at **VMA 0x59000** (first free 4K-aligned address after `.data`; `SizeOfImage` correctly
   grew 0x59000→0x5a000), re-signed with the enrolled `HONOR FMB-P MOK`. UNTESTED against shim.

**Current firmware/boot state:** SB is OFF (Setup Mode). BOOTX64.EFI = Database-Key-signed Limine:
- Non-SB boot: works (signature irrelevant).
- To get SB back: re-enroll sbctl keys (`sbctl enroll-keys --microsoft --firmware-builtin`; SB
  re-arms itself per A1.5). **Do NOT retry the shim chain** in `EFI/shim-staging/`, despite what its
  README.txt says — see §C below. That staging dir is kept as evidence, not as a plan.

**Lesson for the port packaging:** `objcopy --add-section` on PE binaries defaults the new section
to VMA 0 → shim-fatal. Always `--change-section-address .sbat=<first 4K-aligned addr past last
section>` and verify with `objdump -h` (no section below SizeOfHeaders) + `objdump -p | grep
SizeOfImage` before shipping.

---

# C. shim + MOK — TESTED, BROKE THE MACHINE, ABANDONED (2026-07-12/13)

The decision above ("ship shim + MOK") was acted on immediately and **is now retracted.** This section
is the post-mortem and the final architecture. Everything above stands as evidence; only the
*conclusion drawn from it* was wrong.

## C1 — what was built

`EFI/BOOT/BOOTX64.EFI` ← Ubuntu's Microsoft-signed shim; `mmx64.efi` ← MokManager; `grubx64.efi` ←
Limine, signed with a self-made `CN=HONOR FMB-P MOK` (enrolled via `mokutil`).
The MOK enrolled cleanly. Boot gave **`Verification failed: (0x1A) Security Violation`**.

Diagnosis: **Limine ships no `.sbat` section**, and shim 15.x+ refuses any second stage without one.

## C2 — the brick

I injected SBAT with `objcopy --add-section .sbat=... ` **and no load address**. objcopy defaults the
section VMA to **0** — i.e. *inside the PE image headers*. That is a malformed PE, and shim's loader
rejects it **in both Secure Boot and non-Secure-Boot modes**:

```
Section 0 is inside image headers        (SB off)
Malformed section header
Verification failed: (0x03) Unsupported  (SB on)
```

Both boot paths dead. Recovered from Ubuntu by restoring `EFI/BOOT/BOOTX64.EFI` from the
`.sbctl-limine.bak` copy. The experiment is parked in `/boot/EFI/shim-staging/` on the CachyOS ESP,
including a **corrected but never-tested** binary (`.sbat` at VMA 0x59000).

> **PE lesson, if anyone ever does this again:** `--change-section-address .sbat=<4K-aligned address
> past the last section>`, then check `objdump -h` and `SizeOfImage` before booting it.

## C3 — why shim was the wrong answer anyway

The brick was my bug, not shim's. But fixing the bug would not have made shim the right choice:

1. **shim + Limine is a category error.** shim's entire value is that it verifies the *next* image
   loaded through EFI `LoadImage`. **Limine does not load the kernel that way** — it uses its own boot
   protocol, which bypasses EFI verification completely. shim would validate Limine and then have no
   say in anything after it. CachyOS's own wiki says so: *"signing these files isn't necessary on
   Limine because it has a special boot process that bypasses EFI chainloading and signature checks."*
   Limine substitutes **its own BLAKE2B config-and-file hash enforcement** instead. Bolting shim on
   buys a signature check on one binary and zero security thereafter.
2. **shim is not toggle-immune here either.** This BIOS has a **"disable Microsoft 3rd-party CA"**
   toggle. Flip it and the Microsoft-signed shim stops verifying. So the two architectures have
   **mirror-image failure modes**: sbctl dies on the Secure Boot toggle, shim dies on the 3rd-party-CA
   toggle. Neither is proof against a user in the BIOS menu. We would have traded a known failure for
   an equally real one.
3. **The price was enormous.** Adopting shim properly means abandoning Limine for GRUB or
   systemd-boot, reworking the Limine DSDT drop-in, losing `limine-snapper-sync` snapshot boot, and
   MOK-signing every DKMS module (because a shim chain *does* put the kernel into lockdown).

## ★ FINAL ARCHITECTURE: sbctl + Limine — the path CachyOS actually documents ★

Ship the **[supported CachyOS Secure Boot path](https://wiki.cachyos.org/configuration/secure_boot_setup/)**
and treat the firmware quirk as a **documentation problem**, because that is what it is: the failure is
loud, the cause is a single BIOS switch, and the recovery is two minutes and needs no rescue media.

### Enrolment command

```
sudo sbctl enroll-keys --microsoft --firmware-builtin
```

`--firmware-builtin` was **not** what we used before, and it is a strict improvement. VERIFIED: this
firmware does expose its factory defaults as EFI variables, so the flag has real content to enroll —

```
PKDefault    865 B     KEKDefault  3070 B
dbDefault   6998 B     dbxDefault 11792 B
RestoreFactoryDefault  5 B     ← almost certainly the mechanism behind H-toggle
```

It folds the OEM's own KEK and `db` (`FermatB_DB`) into ours **on top of** Microsoft's — a superset of
plain `--microsoft`, keeping anything the factory trusted bootable. It touches only `db` and `KEK`
(`-f, --firmware-builtin[=db,KEK]`), so our own PK is unaffected.

- ⚠️ **REASONED, NOT MEASURED: `--firmware-builtin` does NOT fix H-toggle.** The toggle clears the
  **PK**; no `db` content survives a PK reset. Follows directly from A4, but has not been re-measured
  with the flag in place.
- ⚠️ **Watch for the wiki's ASUS/Gigabyte caveat:** duplicate `builtin-db` entries → Secure Boot
  Violation. We are Insyde/HONOR, so it likely does not apply. Confirm `sbctl status` reads
  `Vendor Keys: microsoft builtin-db` and **not** a doubled `builtin-db builtin-db`.

### Limine ≥ 11.2 Secure Boot enforcement — and the good news about the DSDT

Installed Limine here is **12.4.2**, past the threshold where Secure Boot policy is strictly enforced:
a BLAKE2B config checksum must be enrolled in the Limine EFI binary, and **every path in
`limine.conf` must carry a BLAKE2B hash**.

**VERIFIED — `limine-entry-tool` already hashes our DSDT override:**

```
module_path: boot():/acpi_override.img#85bb869e4211...
```

112 of 113 path lines in the live `limine.conf` are hashed. **The DSDT drop-in is Secure-Boot-clean
under Limine's own enforcement with zero rework.** No shim, no GRUB, no lost snapshots. This is the
single fact that makes the whole shim detour unnecessary.

### The two real gaps — these ARE code, not documentation

1. **The wallpaper is the one unhashed path.** `wallpaper: boot():/limine-splash.png` carries no
   hash. Under Secure Boot, Limine ≥11.2 should panic on it. Fix per the wiki: append
   `#$(b2sum /boot/limine-splash.png)`, or drop the line.
2. **Nothing re-enrolls the config checksum after a kernel update.** VERIFIED by tracing every
   caller: `enroll_config()` in `/usr/lib/limine/limine-common-functions` is invoked **only** by the
   manual `limine-enroll-config` and `limine-reset-enroll`. The pacman hook
   (`80-limine-efi-deploy.hook`), `limine-install` and `limine-mkinitcpio` never call it. It is also
   gated on `ENABLE_ENROLL_LIMINE_CONFIG=yes` in `/etc/default/limine`, which is **unset by default**.
   ⇒ every kernel update rewrites `limine.conf`'s hashes, the enrolled checksum goes **stale**, and
   the next Secure Boot boot panics on mismatch. **This is an upstream gap.** `honor-fmbp` must ship a
   pacman hook that re-runs `limine-enroll-config` after `limine.conf` is regenerated.

### Still to measure (nothing here can change the architecture)

- Does `--firmware-builtin` enroll cleanly on this board (no duplicate `builtin-db`)?
- Does Limine 12.4.2 actually panic without a config checksum / on the unhashed wallpaper, as the
  wiki says? Documented upstream behaviour, **not yet observed on this machine**.
- Optional **B3**: would a Windows-*initiated* TPM clear wipe the key store? Untested. Immaterial —
  the recovery below covers it.

### ⇒ The rule we ship, and the recovery

> **Do not use the BIOS Secure Boot toggle after enrolling.** You never need to: **enrolling a PK
> re-arms Secure Boot by itself** (A1.5).
>
> **If you do flip it — or anything else re-provisions the key store — you are not stranded.** The
> keys persist at `/var/lib/sbctl/keys` and the on-disk signatures stay valid:
>
> ```
> BIOS → Secure Boot: OFF        (firmware enters Setup Mode; CachyOS boots unverified)
> boot CachyOS
> sudo sbctl enroll-keys --microsoft --firmware-builtin
> reboot                         # Secure Boot re-arms ITSELF — do not touch the toggle
> ```
>
> Two minutes, no rescue media, no BIOS visit for the "on" step.

---

# D. Limine config-checksum enforcement — MEASURED LIVE (2026-07-13, second lock-out + repair)

The Cachy session ran the checksum experiment to settle the "still to measure" bullets above. It
worked — every question is now answered on hardware — at the cost of one more (deliberate,
backed-up) lock-out, repaired from Ubuntu the same morning.

## D1 — what the experiment did (Cachy session, 08:37–08:52 local)

1. `sudo sbctl enroll-keys --microsoft --firmware-builtin` → **clean**: `Vendor Keys: microsoft
   builtin-db` (NOT doubled — the ASUS/Gigabyte duplicate-db violation does not apply here), and
   `CN=FermatB_DB` appeared in `db` alongside our keys + Microsoft's. Reboot: **SB armed itself**,
   no BIOS visit. ✅ closes "does --firmware-builtin enroll cleanly".
2. That boot ran under **active Secure Boot with NO config checksum enrolled and the unhashed
   wallpaper line present → booted fine.** `strings` on the binary shows no "not enrolled" panic
   message exists. ✅ closes "does Limine panic without a checksum" — **it does NOT. The wiki
   overstates it.** Limine panics only on a *mismatch* of an *enrolled* checksum.
3. Then the kernel-update simulation: backup `BOOTX64.EFI` → `BOOTX64.EFI.known-good-nochecksum`,
   set `ENABLE_ENROLL_LIMINE_CONFIG=yes`, run `limine-enroll-config`, copy the checksum-carrying
   binary onto the fallback `EFI/BOOT/BOOTX64.EFI` (the one this firmware actually launches —
   generic USB boot entry, no EFI path), then `sudo limine-mkinitcpio` to simulate pacman.
   Result: `limine.conf` rewritten (new b2sum `fa7261…`) and the checksum **re-enrolled — but only
   into `EFI/limine/limine_x64.efi`**. The fallback kept the stale `c12c6b…`.

**⇒ CORRECTION to gap #2 in §C:** with the flag on, `limine-mkinitcpio` *does* re-enroll after a
kernel update (my static trace missed the call path). **The real bug is one level down: enrolment
and re-signing only ever touch `BINARY_TARGET_PATH` (`EFI/limine/limine_x64.efi`). The fallback
`EFI/BOOT/BOOTX64.EFI` is never updated — and on this machine the fallback is the ONLY binary that
boots.** Any machine booting via the removable path gets a stale checksum on every kernel update.

## D2 — live-fire result (the user's reboot)

> `PANIC: !!! CHECKSUM MISMATCH FOR CONFIG FILE !!!`

exactly as predicted. **NEW FINDING:** the panic persists **with Secure Boot toggled OFF** in the
BIOS. Once a checksum is enrolled in the binary, Limine enforces it **unconditionally** — the check
is not gated on SecureBoot=1. There is no "turn SB off to get in" escape from a stale checksum; the
only escapes are fixing the binary from another OS or booting other media.

(Side effect, expected: the BIOS toggle wiped the sbctl keys again — SetupMode=1, factory
re-provision pending. H-toggle re-confirmed in passing, n=3.)

## D3 — repair (Ubuntu, this session)

```
cp EFI/BOOT/BOOTX64.EFI.known-good-nochecksum EFI/BOOT/BOOTX64.EFI    # byte-verified after copy
```

The restored binary has **no enrolled checksum** (only the zeroed placeholder field), signature
`CN=Database Key` intact. It boots regardless of any past or future `limine.conf` change, SB on or
off. `EFI/limine/limine_x64.efi` was left as-is (fresh checksum, never booted on this machine).
`ENABLE_ENROLL_LIMINE_CONFIG=yes` was left set on the Cachy root: harmless in this layout, because
re-enrolment never touches the fallback — which is exactly why it must never be hand-copied over
`BOOTX64.EFI` again without immediately rebooting *once* and never updating a kernel.

## D4 — state as left + the checksum policy decision this forces

- Firmware: **SB OFF / Setup Mode. Keys wiped (again) by the BIOS toggle.** Keys persist at
  `/var/lib/sbctl/keys`; signatures on disk are valid. Recovery after booting Cachy:
  `sudo sbctl enroll-keys --microsoft --firmware-builtin` → reboot (SB re-arms itself).
- Boot path: fallback `BOOTX64.EFI` = signed Limine, **checksum-free** → boots.

For the shipping port, pick one:
1. **Fallback stays checksum-free** (current state). Config integrity is unenforced on the boot
   path; per-file BLAKE2B hashes inside `limine.conf` still cover kernel/initramfs/DSDT. Zero
   moving parts. *Recommended default.*
2. **Enforce on the fallback too**: ship a pacman hook (in `honor-fmbp-dsdt`, running AFTER
   limine's own hooks) that copies `EFI/limine/limine_x64.efi` → `EFI/BOOT/BOOTX64.EFI` whenever it
   changes. Both binaries then always carry the fresh checksum. More parts; protects against
   offline `limine.conf` tampering. Note internal-NVMe installs boot via a real EFI entry pointing
   at `limine_x64.efi`, so this whole fallback problem is USB-install-specific — decide there.

---

# E. The checksum bug is a FALLBACK-PATH artefact — hypothesis confirmed (2026-07-13, Cachy session)

§D concluded "never enrol a config checksum". **That was too broad.** The user's read — *"this is
probably only biting us because of the USB boot; on a standard install to an internal drive this
failure doesn't happen"* — is **CORRECT, and now measured.**

## E1 — the missing piece

This rig had **no path-specific NVRAM entry for Limine at all**. `efibootmgr` showed only the generic
`EFI USB Device (General Generic SATA)` entry (no EFI path) → firmware launches the removable fallback
`\EFI\BOOT\BOOTX64.EFI`. `limine-install` *does* register a `Limine` entry by default
(`register_uefi_entry()`, and it handles `/dev/sda1` fine) — ours was simply absent. On a normal
internal install that entry exists, and it points at `\EFI\limine\limine_x64.efi`.

That is the whole difference. **The binary the tooling maintains and the binary the firmware launches
were not the same file.**

## E2 — the experiment

Created the entry by hand and booted it:

```
efibootmgr --create --disk /dev/sda --part 1 --label Limine \
           --loader '\EFI\limine\limine_x64.efi' --unicode      # -> Boot0003
efibootmgr --bootnext 0003
```

1. **Reboot (hands-off).** `BootCurrent: 0003` — **the firmware honoured it.** SB Enabled, checksum
   matched, booted clean.
   *Tell:* the Limine screen came up **white/unstyled**. That is the `wallpaper:` path (unhashed)
   being **skipped** by the enforcing binary — the visible signature of the checksummed config.
   ⇒ **Limine enforces the per-file hashes ONLY when a config checksum is enrolled.** Without a
   pinned config the hashes are unrooted and it does not bother. (Explains why the checksum-free
   fallback showed the wallpaper under the same SB state.)
2. **Forced a genuine `limine.conf` change** (added a throwaway cmdline param, `limine-update`):
   config `fa7261…` → `3d3a8f…`, and the checksum was **automatically re-enrolled into
   `limine_x64.efi`** — the very binary Boot0003 launches.
3. **Reboot (hands-off). IT BOOTED.** `BootCurrent: 0003`, SB Enabled, checksum matched the *new*
   config, and `loglevel=4` was live in `/proc/cmdline` — proving the changed config was the one
   actually consumed. Then reverted the param; the checksum re-enrolled again, clean.

**This is exactly the sequence that bricked the machine in §D — and on the path-specific entry it
self-heals.**

## E3 — verdict

| firmware boots… | on a `limine.conf` change | result |
|---|---|---|
| `\EFI\limine\limine_x64.efi` (path-specific NVRAM entry — **normal internal install**) | checksum re-enrolled automatically | ✅ **self-healing** |
| `\EFI\BOOT\BOOTX64.EFI` (removable fallback — **USB install / generic device entry**) | never re-enrolled | ⛔ stale → **unrecoverable panic** |

## E4 — shipping policy (supersedes §D4)

- **Enrol the checksum IF AND ONLY IF the firmware boots Limine by path.** Check with
  `efibootmgr | grep BootCurrent` and read what that entry points at. It is the only thing that roots
  the trust chain past the bootloader, and it is self-maintaining. `ENABLE_ENROLL_LIMINE_CONFIG=yes`.
- **NEVER enrol one on the fallback path**, and **always keep `EFI/BOOT/BOOTX64.EFI` signed but
  checksum-FREE.** It is the rescue binary: it boots under any firmware state and any config. This
  firmware is erratic about NVRAM entries and USB detection, so you *will* land on it eventually.
  **Never copy `limine_x64.efi` over `BOOTX64.EFI`** — that arms the self-destruct.
- **Wallpaper:** hash it (`b2sum /boot/limine-splash.png`, append as `…limine-splash.png#<hash>`).
  **The theme block at the top of `limine.conf` is user-owned and survives regeneration** — verified.
  Unhashed is only cosmetic (white screen), never fatal.

## E5 — what the CachyOS wiki gets wrong (all measured, Limine 12.4.2)

| Wiki | Reality |
|---|---|
| Panics if no config checksum is enrolled | **False.** That panic string is not in the binary. It boots fine. |
| Every path must carry a hash or it panics | **Half-true** (corrected 2026-10-07 from the source, `common/lib/uri.c`): kernel/module paths **do** panic when unhashed; only `wallpaper` and `TERM_FONT` are skipped (`gterm.c`), which is what we observed. |
| — | It panics **only** on a **mismatch** of an **enrolled** checksum… |
| — | …and that check is **NOT gated on Secure Boot**. SB-off does not rescue you. |
| `enroll-keys --microsoft --firmware-builtin` | ✅ correct, and clean here: `Vendor Keys: microsoft builtin-db` (not doubled), `FermatB_DB` lands in `db`. |
