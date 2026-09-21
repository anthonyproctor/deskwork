#!/usr/bin/env bash
# Turns a built Project Coldfall.app into the zip a GitHub release ships.
#
#   scripts/release-zip.sh                       # ~/Applications/Project Coldfall.app -> dist/Project-Coldfall.app.zip
#   scripts/release-zip.sh <some.app> <out.zip>
#
# The bundle build-app.sh makes is for this machine, not for publishing:
#
#   * Info.plist records DWSourceRoot, the checkout it was built from, so
#     self-update knows where to rebuild. That is a path under the builder's
#     home directory. The first two releases shipped it.
#   * The binaries keep debug symbols, and those record the path of every
#     object file built, which is also under the builder's home directory.
#     The first three releases shipped those. `strip -S` drops them; it does
#     not change what the app does.
#   * It may be signed with a personal local certificate. Releases are signed
#     ad hoc instead, so no certificate of anyone's goes out with them.
#   * Extended attributes ride along into a zip as `._` files. Finder hides
#     them on unzip, but `unzip` writes them into the bundle, and a bundle with
#     extra files fails its signature check.
#
# So this works on a copy, strips all four, and then checks the zip it made
# the way a stranger would open it: plain `unzip`, then codesign, then a search
# for the builder's home directory and user name. Any failure stops the script.
set -euo pipefail

SRC="${1:-$HOME/Applications/Project Coldfall.app}"
OUT="${2:-$(cd "$(dirname "$0")/.." && pwd)/dist/Project-Coldfall.app.zip}"
[ -d "$SRC" ] || { echo "no app at $SRC (run scripts/build-app.sh first)"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
name="$(basename "$SRC")"
ditto "$SRC" "$work/$name"
app="$work/$name"

/usr/libexec/PlistBuddy -c "Delete :DWSourceRoot" "$app/Contents/Info.plist" 2>/dev/null || true
for bin in "$app"/Contents/MacOS/*; do strip -S "$bin" 2>/dev/null; done
xattr -cr "$app"
codesign --force --deep -s - "$app" >/dev/null 2>&1
codesign --verify --deep --strict "$app"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
(cd "$work" && ditto -c -k --norsrc --noextattr --keepParent "$name" "$OUT")

# Open it as someone downloading it would.
check="$work/check"
mkdir "$check"
(cd "$check" && unzip -q "$OUT")
if unzip -l "$OUT" | grep -q '/\._'; then echo "zip carries ._ metadata files"; exit 1; fi
codesign --verify --deep --strict "$check/$name" || { echo "signature fails after unzip"; exit 1; }
# The home path, not the bare user name: the repo's own GitHub link contains
# the owner's name on purpose.
leaks="$( (grep -rlF "$HOME/" "$check/$name"; grep -rlF "/Users/$(whoami)/" "$check/$name") 2>/dev/null | sort -u || true)"
if [ -n "$leaks" ]; then
  echo "the bundle still names this machine's home directory:"
  echo "$leaks"
  exit 1
fi

echo "release zip: $OUT"
echo "  $(du -h "$OUT" | cut -f1), signed ad hoc, verified after a plain unzip, no home paths"
