#!/bin/sh
# platform: macOS-only -- shipyard's stage_product.sh, build_component_pkg.sh and set_install_floor.sh run PlistBuddy, pkgbuild and productbuild
#   usage: sh build/package-pkg.sh BINARY
#          Writes dist/stevedore-<VER>.pkg, installing BINARY as /usr/local/mavergreen/stevedore/bin/stevedore,
#          and dist/build-info.txt; VER is the first line of ./VERSION. BINARY must carry exactly the
#          x86_64 and arm64 slices. Prints the pkg's path.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
STEVEDORE_ROOT="$(dirname "$SELF")"
. "$SELF/lib.sh"
. "$SELF/msc.sh"
cd "$STEVEDORE_ROOT"
[ $# -eq 1 ] || { echo "usage: sh build/package-pkg.sh BINARY" >&2; exit 2; }
BIN="$1"
[ -f "$BIN" ] && [ -x "$BIN" ] || { echo "package-pkg: no executable at $BIN" >&2; exit 1; }
[ -f VERSION ] || { echo "package-pkg: no VERSION file; the release workflow's ver job writes it" >&2; exit 1; }
VER="$(sed -n 1p VERSION | tr -d ' \t')"
[ -n "$VER" ] || { echo "package-pkg: VERSION is empty" >&2; exit 1; }
LIPO="${LIPO:-$(sh "$SELF/fetch-clang22.sh")/bin/llvm-lipo}"
raw="$("$LIPO" -archs "$BIN")" || { echo "package-pkg: $LIPO cannot read $BIN" >&2; exit 1; }
archs="$(printf '%s\n' $raw | LC_ALL=C sort | tr '\n' ' ')"
[ "$archs" = "arm64 x86_64 " ] || { echo "package-pkg: $BIN carries [$raw], not exactly arm64 and x86_64" >&2; exit 1; }
got="$("$BIN" --version 2>/dev/null || :)"
[ "$got" = "stevedore $VER" ] || { echo "package-pkg: $BIN --version says '$got', not 'stevedore $VER'" >&2; exit 1; }

BUILD_ROOT="$(stevedore_build_root)"
mkdir -p "$BUILD_ROOT"
WORK="$(mktemp -d "$BUILD_ROOT/stevedore-package.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM

P="$WORK/root/usr/local/mavergreen/stevedore"
mkdir -p "$P/bin"
cp "$BIN" "$P/bin/stevedore"
chmod 755 "$P/bin/stevedore"

sh "$SHIPYARD_SCRIPTS/stage_product.sh" --stage "$WORK/root" --product stevedore \
  --name "stevedore for Mavericks" --version "$VER" --scripts-out "$WORK/scripts" >&2
sh "$SHIPYARD_SCRIPTS/build_component_pkg.sh" --root "$WORK/root" --identifier dev.mavergreen.stevedore \
  --version "$VER" --install-location / --scripts "$WORK/scripts" --out "$WORK/component.pkg" >&2

mkdir -p dist
out="dist/stevedore-$VER.pkg"
rm -f "$out"
sh "$SHIPYARD_SCRIPTS/set_install_floor.sh" --identifier dev.mavergreen.stevedore \
  --title "stevedore for Mavericks $VER" --component "$WORK/component.pkg" \
  --out "$out" --min-os 10.9.5 --host-arch x86_64,arm64 --require-scripts >&2
sh "$SHIPYARD_SCRIPTS/build-info.sh" dist/build-info.txt "pkg=stevedore-$VER.pkg" \
  identifier=dev.mavergreen.stevedore arch=x86_64,arm64 \
  "zlib=$(sed -n 1p components/zlib/version)" "clang22=$(sed -n 1p components/clang22/version)"
printf '%s\n' "$out"
