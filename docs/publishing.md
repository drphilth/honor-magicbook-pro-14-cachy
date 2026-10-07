# Publishing — GitHub releases and the AUR

## Where things stand

| Channel | Status |
|---|---|
| **This repo** | Public. Each release is a tag `v<pkgver>-<pkgrel>` plus a GitHub Release. |
| **GitHub Releases** | ✅ The prebuilt packages + `SHA256SUMS` are attached to each release. They are built in a clean Arch chroot (`makechrootpkg`), not on a developer machine. |
| **AUR** | ⏳ **Prepared, not yet pushed.** Both PKGBUILDs build cleanly in a chroot, and the output is byte-identical to the released packages. Blocked only on AUR account registration, which is paused (it was paused once before after the June 2026 malicious-package wave, and has been again since). |

## Why AUR, not a binary repo

The closest analogue to the Ubuntu PPA would be a **self-hosted binary pacman repo**: a `[honor-fmbp]`
section in `/etc/pacman.conf`, GPG-signed `.pkg.tar.zst` files and a `repo-add` database. But
"binary" buys much less here than on Debian. **The DKMS modules have to compile on the user's
machine anyway** (that is what DKMS is), and everything except the fingerprint driver is plain files.
So a binary repo would only save the libfprint build, which takes a couple of minutes.

**AUR** is the idiomatic Arch channel, it is discoverable, and CachyOS ships `paru` preinstalled:

```sh
paru -S honor-magicbook-pro-14
```

## How the AUR packaging works

The in-repo `honor-fmbp/PKGBUILD` builds from the tree it sits in (`$startdir`). That is right for
a checkout, but the AUR forbids it. **`aur/honor-fmbp/PKGBUILD` is generated from it** by
`aur/regenerate.sh`, which changes only two things: the header, and the payload source, which
becomes the release tarball pinned by sha256:

```sh
source=("$pkgbase-$_tag.tar.gz::$url/archive/refs/tags/v$_tag.tar.gz")
```

**Never edit the AUR PKGBUILD by hand.** Edit `honor-fmbp/PKGBUILD` and regenerate.

The fingerprint package needs none of this. Its
[Arch packaging](https://github.com/drphilth/honor-fmbp-libfprint-sdcp/tree/main/arch) pins
**upstream libfprint's git commit directly**, so nothing is vendored or hosted.

## Releasing a new version

1. Bump `pkgrel` (or `pkgver`) in `honor-fmbp/PKGBUILD` and add a `CHANGELOG.md` entry.
2. Build in a clean chroot, test on the hardware, and replace the root-level prebuilts and
   `SHA256SUMS`:
   ```sh
   cd honor-fmbp && makechrootpkg -c -r ~/chroots/arch
   ```
3. Commit, tag `v<pkgver>-<pkgrel>`, push the commit and the tag, and create the GitHub Release
   with the packages + `SHA256SUMS` attached.
4. Download the tag tarball and take its sha256. **Download it twice** and check the hashes match:
   GitHub generates archives on the fly.
   ```sh
   curl -sL https://github.com/drphilth/honor-magicbook-pro-14-cachy/archive/refs/tags/v<tag>.tar.gz | sha256sum
   ```
5. `aur/regenerate.sh <sha256>`, commit, then build `aur/honor-fmbp` in the chroot. This exercises
   the real download path.
6. Copy `aur/honor-fmbp/{PKGBUILD,.SRCINFO,*.install}` into the AUR clone
   (`ssh://aur@aur.archlinux.org/honor-fmbp.git`), commit, and push.

## Still to do (once AUR registration reopens)

1. Create the AUR account (non-disposable email; verify within 24 h) and register a dedicated SSH
   key (`~/.ssh/aur` + a `Host aur.archlinux.org` block in `~/.ssh/config`).
2. Push `honor-fmbp-libfprint-sdcp` from the fork repo's `arch/` directory, then `honor-fmbp` from
   `aur/honor-fmbp/`. The AUR entry is named after the **pkgbase**; users still
   `paru -S honor-magicbook-pro-14` and the helper resolves it.
3. Verify from the user's side: remove the local packages, run `paru -S honor-magicbook-pro-14`,
   reboot, and check the DSDT, DKMS modules and HDR.
4. Make `paru` the primary install route in the README and the runbook.

## What does not change

The **installer ISO keeps its own offline copy of the packages** regardless. The pre-first-boot
install (runbook §2.5) has to work with no network at all, so `remaster-cachyos-iso.sh` grafting the
built `.pkg.tar.zst` files onto the ISO stays exactly as it is. The AUR is for updating a machine that
is already up.
