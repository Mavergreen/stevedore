#!/bin/sh
# platform: macOS-only -- build/package-pkg.sh stages with PlistBuddy, builds the base component with pkgbuild, and fetch-stevedore.sh unpacks with pkgutil
#   usage: sh tests/package-pkg-test.sh
#          The release is packaged by the pinned stevedore, not by pkgbuild or productbuild: package-pkg.sh
#          calls no tool but stevedore's component and product for the pkg; components/stevedore pins a
#          release and the digest of its pkg; fetch-stevedore.sh unpacks the binary of a release it can verify
#          against that digest, and refuses any other. Against a synthetic release served from a file:// tree,
#          package-pkg.sh then writes a pkg whose Distribution holds the install floor, the base first and
#          the stevedore component, whose payload holds the binary and the updater, and which is the same pkg
#          for the same commit.
set -eu
STEVEDORE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$STEVEDORE_ROOT/build/lib.sh"
B="$(stevedore_build_dir)"
SD="${STEVEDORE:-$B/stevedore}"
SHIPYARD_SCRIPTS="${SHIPYARD_SCRIPTS:-/usr/local/mavergreen/shipyard/share/cmake/MavericksShipyard/scripts}"
export SHIPYARD_SCRIPTS
fail() { echo "FAIL: $*" >&2; exit 1; }
P="$STEVEDORE_ROOT/build/package-pkg.sh"

[ "$(uname -s)" = Darwin ] && command -v pkgbuild >/dev/null 2>&1 || { echo "package-pkg-test: SKIP (no pkgbuild)"; exit 77; }
[ -f "$SHIPYARD_SCRIPTS/build-base-component.sh" ] || { echo "package-pkg-test: SKIP (no build-base-component.sh in $SHIPYARD_SCRIPTS)"; exit 77; }
[ -x "$SD" ] || fail "no stevedore binary at $SD -- build it with sh build/build.sh, or set STEVEDORE"

if sed 's/^[[:space:]]*#.*//' "$P" | grep -Eq 'pkgbuild|productbuild|build_component_pkg|set_install_floor'; then
  fail "build/package-pkg.sh calls a tool other than stevedore to write the pkg"
fi
sed 's/^[[:space:]]*#.*//' "$P" | grep -q '"\$PACKAGER" component ' || fail "build/package-pkg.sh does not write the component with the packager"
sed 's/^[[:space:]]*#.*//' "$P" | grep -q '"\$PACKAGER" product ' || fail "build/package-pkg.sh does not write the product with the packager"

V="$(tr -d ' \t\n' < "$STEVEDORE_ROOT/components/stevedore/version")"
sha="$(tr -d ' \t\n' < "$STEVEDORE_ROOT/components/stevedore/sha256")"
case "$V" in ''|*[!0-9.]*) fail "components/stevedore/version holds '$V', not a YYYYMMDD.N release" ;; esac
[ "${#sha}" -eq 64 ] && case "$sha" in *[!0-9a-f]*) false ;; esac || fail "components/stevedore/sha256 holds no SHA-256"

T="$(mktemp -d "${TMPDIR:-/tmp}/package-pkg.XXXXXX")"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
FAKEV=20990101.7

mkdir -p "$T/rel/Mavergreen/stevedore/releases/download/$FAKEV" "$T/pl/usr/local/mavergreen/stevedore/bin" "$T/pkgs" "$T/scripts"
printf '#!/bin/sh\necho "stevedore %s"\n' "$FAKEV" > "$T/pl/usr/local/mavergreen/stevedore/bin/stevedore"
chmod 755 "$T/pl/usr/local/mavergreen/stevedore/bin/stevedore"
"$SD" component --root "$T/pl" --identifier dev.mavergreen.stevedore --version "$FAKEV" --install-location / \
  --mtime 1672574400 --out "$T/pkgs/stevedore.pkg"
printf '<?xml version="1.0" encoding="utf-8"?>\n<installer-gui-script minSpecVersion="1">\n<choices-outline><line choice="default"><line choice="dev.mavergreen.stevedore"/></line></choices-outline>\n<choice id="default"/>\n<choice id="dev.mavergreen.stevedore"><pkg-ref id="dev.mavergreen.stevedore"/></choice>\n<pkg-ref id="dev.mavergreen.stevedore" version="0">stevedore.pkg</pkg-ref>\n</installer-gui-script>\n' > "$T/dist.xml"
REL="$T/rel/Mavergreen/stevedore/releases/download/$FAKEV"
"$SD" product --distribution "$T/dist.xml" --package "$T/pkgs/stevedore.pkg" --mtime 1672574400 --out "$REL/stevedore-$FAKEV.pkg"
good="$(shasum -a 256 "$REL/stevedore-$FAKEV.pkg" | cut -c1-64)"

repo() {  # repo DIR DIGEST -- a copy of the build scripts and pins, pinned to the synthetic release
  mkdir -p "$1/components/stevedore"
  cp -R "$STEVEDORE_ROOT/build" "$1/build"
  printf '%s\n' "$FAKEV" > "$1/components/stevedore/version"
  printf '%s\n' "$2" > "$1/components/stevedore/sha256"
}
fetch() {  # fetch DIR CACHE -- fetch-stevedore.sh of the copy in DIR, against the synthetic release
  MAVERGREEN_RELEASES="file://$T/rel" MAVERGREEN_PKG_CACHE="$2" MAVERICKS_BUILD_ROOT="$T/build-root" SHIPYARD_FETCH_BACKOFF=0 \
    sh "$1/build/fetch-stevedore.sh"
}

repo "$T/bad" "$(printf 0%.0s $(seq 1 64))"
if fetch "$T/bad" "$T/bad-cache" > "$T/bad.out" 2>&1; then fail "fetch-stevedore.sh accepted a pkg that is not the pinned digest"; fi
grep -q 'not the pinned' "$T/bad.out" || fail "fetch-stevedore.sh refused the wrong digest without saying so: $(tr '\n' '|' < "$T/bad.out")"
[ ! -e "$T/build-root/stevedore-packager" ] || [ -z "$(ls "$T/build-root/stevedore-packager" 2>/dev/null)" ] \
  || fail "fetch-stevedore.sh left an unverified binary behind"

mkdir "$T/nopin" && repo "$T/nopin" "" && rm "$T/nopin/components/stevedore/sha256"
if fetch "$T/nopin" "$T/nopin-cache" > "$T/nopin.out" 2>&1; then fail "fetch-stevedore.sh ran with no pinned digest"; fi
grep -q 'pin-stevedore.sh' "$T/nopin.out" || fail "fetch-stevedore.sh with no digest does not name pin-stevedore.sh: $(tr '\n' '|' < "$T/nopin.out")"

repo "$T/good" "$good"
prefix="$(fetch "$T/good" "$T/good-cache")" || fail "fetch-stevedore.sh refused the pinned release"
[ "$("$prefix/bin/stevedore" --version)" = "stevedore $FAKEV" ] || fail "the fetched binary is not the pinned release's"
[ "$(fetch "$T/good" "$T/good-cache")" = "$prefix" ] || fail "a second fetch-stevedore.sh did not reuse the first's prefix"

mkdir -p "$T/lipo" "$T/app/stevedore-updater.app/Contents/MacOS"
printf '#!/bin/sh\necho "arm64 x86_64"\n' > "$T/lipo/lipo"
chmod 755 "$T/lipo/lipo"
printf '#!/bin/sh\necho "stevedore 20990102.1"\n' > "$T/stevedore"
chmod 755 "$T/stevedore"
: > "$T/app/stevedore-updater.app/Contents/MacOS/stevedore-updater"
chmod 755 "$T/app/stevedore-updater.app/Contents/MacOS/stevedore-updater"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $(sh "$SHIPYARD_SCRIPTS/product-name.sh" updater-bundle-id stevedore)" \
  -c "Add :SUFeedURL string $(sh "$SHIPYARD_SCRIPTS/product-name.sh" feed stevedore)" \
  -c "Add :CFBundleShortVersionString string 20990102.1" -c "Add :CFBundleVersion string 20990102.1" \
  -c "Add :CFBundleExecutable string stevedore-updater" -c "Add :CFBundlePackageType string APPL" \
  "$T/app/stevedore-updater.app/Contents/Info.plist" >/dev/null

mkdir "$T/work"
cp -R "$STEVEDORE_ROOT/build" "$T/work/build"
printf '20990102.1\n' > "$T/work/VERSION"
mkdir -p "$T/work/components"
cp -R "$STEVEDORE_ROOT/components/zlib" "$STEVEDORE_ROOT/components/clang22" "$T/work/components/"
git -C "$T/work" init -q
git -C "$T/work" add .
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com \
  GIT_COMMITTER_DATE="2023-01-01T12:00:00Z" GIT_AUTHOR_DATE="2023-01-01T12:00:00Z" git -C "$T/work" commit -q -m c
pkg() {  # pkg DIR -- package-pkg.sh of the copy in DIR with the synthetic inputs, packaged by $SD
  ( cd "$1" && LIPO="$T/lipo/lipo" STEVEDORE_PACKAGER="$SD" MAVERICKS_BUILD_ROOT="$T/build-root" \
      sh build/package-pkg.sh "$T/stevedore" "$T/app/stevedore-updater.app" )
}
pkg "$T/work" > "$T/pkg.out" 2> "$T/pkg.err" || fail "package-pkg.sh failed: $(tail -5 "$T/pkg.err" | tr '\n' '|')"
out="$T/work/dist/stevedore-20990102.1.pkg"
[ "$(cat "$T/pkg.out")" = dist/stevedore-20990102.1.pkg ] && [ -f "$out" ] || fail "package-pkg.sh printed '$(cat "$T/pkg.out")' and wrote no $out"
pkgutil --check-signature "$out" >/dev/null 2>&1 || :
pkgutil --expand "$out" "$T/x" || fail "pkgutil cannot expand the pkg"
grep -q 'os-version min="10.9.5"' "$T/x/Distribution" || fail "the Distribution holds no 10.9.5 floor"
grep -q 'hostArchitectures="x86_64,arm64"' "$T/x/Distribution" || fail "the Distribution does not take both architectures"
[ "$(sed -n 's/.*<line choice="\([^"]*\)".*/\1/p' "$T/x/Distribution" | grep -v '^default$' | sed -n 1p)" = dev.mavergreen.base ] \
  || fail "the base is not first in the Distribution"
[ -d "$T/x/stevedore.pkg" ] && [ -d "$T/x/mavergreen-base.pkg" ] || fail "the product holds $(ls "$T/x" | tr '\n' ' '), not stevedore.pkg and mavergreen-base.pkg"
grep -q 'identifier="dev.mavergreen.stevedore"' "$T/x/stevedore.pkg/PackageInfo" || fail "the component's identifier is not dev.mavergreen.stevedore"
grep -q 'version="20990102.1"' "$T/x/stevedore.pkg/PackageInfo" || fail "the component's version is not 20990102.1"
pkgutil --expand-full "$out" "$T/xf" >/dev/null 2>&1 || fail "pkgutil cannot expand the pkg's payloads"
[ "$("$T/xf/stevedore.pkg/Payload/usr/local/mavergreen/stevedore/bin/stevedore" --version)" = "stevedore 20990102.1" ] \
  || fail "the payload does not hold the binary"
[ -d "$T/xf/stevedore.pkg/Payload/Library/Application Support/Mavergreen/stevedore-updater.app" ] || fail "the payload does not hold the updater"
[ -f "$T/xf/stevedore.pkg/Scripts/postinstall" ] || fail "the component carries no postinstall"
cp "$out" "$T/first.pkg"
pkg "$T/work" >/dev/null 2>&1 || fail "the second package-pkg.sh failed"
pkgutil --expand "$out" "$T/y"
cmp -s "$T/x/stevedore.pkg/Bom" "$T/y/stevedore.pkg/Bom" && cmp -s "$T/x/stevedore.pkg/Payload" "$T/y/stevedore.pkg/Payload" \
  && cmp -s "$T/x/stevedore.pkg/PackageInfo" "$T/y/stevedore.pkg/PackageInfo" || fail "the same commit packaged twice gave different components"
echo "package-pkg-test: ok"
