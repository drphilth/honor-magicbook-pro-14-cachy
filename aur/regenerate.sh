#!/usr/bin/env bash
# Regenerate aur/honor-fmbp/PKGBUILD (+ .SRCINFO) from honor-fmbp/PKGBUILD, which is the source
# of truth. The only differences: the payload comes from the tagged release tarball (pinned by
# sha256) instead of $startdir, and the header comment.
#   aur/regenerate.sh <tarball-sha256>
set -euo pipefail
cd "$(dirname "$0")/.."
sha=${1:?usage: aur/regenerate.sh <sha256 of the v<pkgver>-<pkgrel> tag tarball>}
out=aur/honor-fmbp
cp honor-fmbp/honor-fmbp-dsdt.install honor-fmbp/honor-fmbp-hdr.install "$out/"
python3 - "$sha" <<'PY'
import pathlib, sys
src = pathlib.Path("honor-fmbp/PKGBUILD").read_text()
hdr = """# Maintainer: Philip Walsh <packages@drphilth.com>
#
# HONOR MagicBook Pro 14 2025 (FMB-P) — Arch/CachyOS enablement.
# AUR build of https://github.com/drphilth/honor-magicbook-pro-14-cachy — generated from that
# repo's honor-fmbp/PKGBUILD (which builds in-tree) by aur/regenerate.sh, which switches the
# payload to a pinned release tarball. Edit the in-repo PKGBUILD, not this one.

"""
out = hdr + src[src.index("pkgbase="):]
old = "source=()\nsha256sums=()\n"
assert out.count(old) == 1
out = out.replace(old,
    '_tag="${pkgver}-${pkgrel}"\n'
    '_srcname="honor-magicbook-pro-14-cachy-${_tag}"\n'
    'source=("$pkgbase-$_tag.tar.gz::$url/archive/refs/tags/v$_tag.tar.gz")\n'
    f"sha256sums=('{sys.argv[1]}')\n")
out = out.replace("$startdir/", "$srcdir/$_srcname/honor-fmbp/")
assert "$startdir" not in out
pathlib.Path("aur/honor-fmbp/PKGBUILD").write_text(out)
PY
(cd "$out" && makepkg --printsrcinfo > .SRCINFO)
echo "regenerated $out (sha256 $sha)"
