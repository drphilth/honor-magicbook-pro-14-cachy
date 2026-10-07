# Publishing — the AUR (the PPA equivalent)

**Nothing here has been done yet.** This repo is currently local-only and unpublished; the packages
build and install from a checkout (`cd honor-fmbp && makepkg -si`), which is how they have been
tested. This file records what publishing actually requires, so the work is scoped rather than
half-remembered.

## Why AUR, not a binary repo

The PPA's closest literal analogue is a **self-hosted binary pacman repo** (a `[honor-fmbp]` section
in `/etc/pacman.conf` + GPG-signed `.pkg.tar.zst` + a `repo-add` database, hostable on GitHub
Releases). But "binary" buys much less here than it does on Debian: the **DKMS modules must compile
on the user's machine anyway** — that is what DKMS is — and everything except the fingerprint driver
is pure files. So the only build a binary repo would save is the libfprint fork (a couple of
minutes).

**AUR** is the idiomatic Arch channel, it is discoverable, and CachyOS ships `paru` preinstalled:

```sh
paru -S honor-magicbook-pro-14
```

## What has to change

AUR PKGBUILDs must fetch their sources from a **public URL**. The PKGBUILD in this repo deliberately
does not: it builds from the tree it sits in (`$startdir`), which is right for a self-contained
repo and for local testing, but AUR forbids it.

So AUR needs a *thin* PKGBUILD that fetches a tagged release of this repo:

```sh
source=("$pkgbase-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
```

The fingerprint package is already done and needs none of this: its
[Arch packaging](https://github.com/drphilth/honor-fmbp-libfprint-sdcp/tree/main/arch) pins
**upstream libfprint's git commit directly**, so nothing is vendored or hosted.

## Steps

1. **Publish this repo** (`drphilth/honor-magicbook-pro-14-cachy`) and tag the current release (`v1.0.5-4`).
   → *The former blocker is cleared: the full install path (remastered ISO → internal NVMe →
   Secure Boot on → all hardware) was executed and verified 2026-07-12/13.*
   → *Before pushing: squash or rewrite the local history — it predates the secrets scrub.*
2. Write the AUR PKGBUILD fetching that tag; regenerate `.SRCINFO`
   (`makepkg --printsrcinfo > .SRCINFO`).
3. Create an **AUR account** and register an SSH key (aur.archlinux.org).
4. Push two AUR repos, one per `pkgbase`:
   - `honor-fmbp` — produces all six packages, including the `honor-magicbook-pro-14` metapackage.
   - `honor-fmbp-libfprint-sdcp` — from the fork repo's `arch/` directory (already AUR-ready).

   The AUR entry is named after the **pkgbase**, but users still `paru -S honor-magicbook-pro-14`;
   the helper resolves the metapackage to its pkgbase.

## What does not change

The **installer ISO keeps its own offline copy of the packages** regardless. The pre-first-boot
install (runbook §2.5) has to work with no network at all, so `remaster-cachyos-iso.sh` grafting the
built `.pkg.tar.zst` files onto the ISO stays exactly as it is. AUR is for updating a machine that
is already up.
