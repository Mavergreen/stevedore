#!/bin/sh
# platform: macOS-only -- shipyard's stage_product.sh and build-base-component.sh run PlistBuddy and pkgbuild; the pkg itself is written by the pinned stevedore
#   usage: sh build/package-pkg.sh BINARY UPDATER_APP
#          Writes dist/stevedore-<VER>.pkg, installing BINARY as /usr/local/mavergreen/stevedore/bin/stevedore
#          and UPDATER_APP (build/build-updater.sh's stevedore-updater.app) as stevedore's Sparkle updater,
#          and dist/build-info.txt; VER is the first line of ./VERSION. BINARY and the updater's executable
#          must each carry exactly the x86_64 and arm64 slices. Prints the pkg's path. The pkg is written by the
#          stevedore build/fetch-stevedore.sh fetches (STEVEDORE_PACKAGER names another), with the commit's
#          time as every mtime.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
STEVEDORE_ROOT="$(dirname "$SELF")"
. "$SELF/lib.sh"
. "$SELF/msc.sh"
cd "$STEVEDORE_ROOT"
[ $# -eq 2 ] || { echo "usage: sh build/package-pkg.sh BINARY UPDATER_APP" >&2; exit 2; }
BIN="$1"; APP="${2%/}"
[ -f "$BIN" ] && [ -x "$BIN" ] || { echo "package-pkg: no executable at $BIN" >&2; exit 1; }
[ "$(basename "$APP")" = stevedore-updater.app ] && [ -x "$APP/Contents/MacOS/stevedore-updater" ] \
  || { echo "package-pkg: $APP is not a stevedore-updater.app" >&2; exit 1; }
[ -f VERSION ] || { echo "package-pkg: no VERSION file; the release workflow's ver job writes it" >&2; exit 1; }
VER="$(sed -n 1p VERSION | tr -d ' \t')"
[ -n "$VER" ] || { echo "package-pkg: VERSION is empty" >&2; exit 1; }
PACKAGER="${STEVEDORE_PACKAGER:-$(sh "$SELF/fetch-stevedore.sh")/bin/stevedore}"
[ -x "$PACKAGER" ] || { echo "package-pkg: no packager at $PACKAGER" >&2; exit 1; }
LIPO="${LIPO:-$(sh "$SELF/fetch-clang22.sh")/bin/llvm-lipo}"
for m in "$BIN" "$APP/Contents/MacOS/stevedore-updater"; do
  raw="$("$LIPO" -archs "$m")" || { echo "package-pkg: $LIPO cannot read $m" >&2; exit 1; }
  archs="$(printf '%s\n' $raw | LC_ALL=C sort | tr '\n' ' ')"
  [ "$archs" = "arm64 x86_64 " ] || { echo "package-pkg: $m carries [$raw], not exactly arm64 and x86_64" >&2; exit 1; }
done
got="$("$BIN" --version 2>/dev/null || :)"
[ "$got" = "stevedore $VER" ] || { echo "package-pkg: $BIN --version says '$got', not 'stevedore $VER'" >&2; exit 1; }

BUILD_ROOT="$(stevedore_build_root)"
mkdir -p "$BUILD_ROOT"
WORK="$(mktemp -d "$BUILD_ROOT/stevedore-package.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM

P="$WORK/root/usr/local/mavergreen/stevedore"
mkdir -p "$P/bin" "$WORK/pkgs"
cp "$BIN" "$P/bin/stevedore"
chmod 755 "$P/bin/stevedore"

sh "$SHIPYARD_SCRIPTS/stage_product.sh" --stage "$WORK/root" --product stevedore \
  --name "stevedore for Mavericks" --version "$VER" --updater-app "$APP" --scripts-out "$WORK/scripts" >&2
MT="$(git log -1 --format=%ct)"
sh "$SHIPYARD_SCRIPTS/build-base-component.sh" --out "$WORK/pkgs/mavergreen-base.pkg" >&2
"$PACKAGER" component --root "$WORK/root" --identifier dev.mavergreen.stevedore --version "$VER" \
  --install-location / --scripts "$WORK/scripts" --mtime "$MT" --out "$WORK/pkgs/stevedore.pkg" >&2
cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>stevedore for Mavericks $VER</title>
    <allowed-os-versions><os-version min="10.9.5"/></allowed-os-versions>
    <options customize="never" require-scripts="true" hostArchitectures="x86_64,arm64"/>
    <choices-outline>
        <line choice="default">
            <line choice="dev.mavergreen.base"/>
            <line choice="dev.mavergreen.stevedore"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="dev.mavergreen.base" visible="false"><pkg-ref id="dev.mavergreen.base"/></choice>
    <choice id="dev.mavergreen.stevedore" visible="false"><pkg-ref id="dev.mavergreen.stevedore"/></choice>
    <pkg-ref id="dev.mavergreen.base" version="0" onConclusion="none">mavergreen-base.pkg</pkg-ref>
    <pkg-ref id="dev.mavergreen.stevedore" version="0" onConclusion="none">stevedore.pkg</pkg-ref>
</installer-gui-script>
XML

mkdir -p dist
out="dist/stevedore-$VER.pkg"
rm -f "$out"
"$PACKAGER" product --distribution "$WORK/distribution.xml" --package "$WORK/pkgs/mavergreen-base.pkg" \
  --package "$WORK/pkgs/stevedore.pkg" --mtime "$MT" --out "$out" >&2
pkgutil --expand "$out" "$WORK/expanded" >&2
[ "$(grep -o 'os-version min="[0-9.]*"' "$WORK/expanded/Distribution")" = 'os-version min="10.9.5"' ] \
  || { echo "package-pkg: the install floor 10.9.5 is not in $out" >&2; exit 1; }
[ "$(sed -n 's/.*<line choice="\([^"]*\)".*/\1/p' "$WORK/expanded/Distribution" | grep -v '^default$' | sed -n 1p)" = dev.mavergreen.base ] \
  || { echo "package-pkg: dev.mavergreen.base is not first in $out" >&2; exit 1; }
sh "$SHIPYARD_SCRIPTS/build-info.sh" dist/build-info.txt "pkg=stevedore-$VER.pkg" \
  identifier=dev.mavergreen.stevedore arch=x86_64,arm64 \
  "zlib=$(sed -n 1p components/zlib/version)" "clang22=$(sed -n 1p components/clang22/version)"
printf '%s\n' "$out"
