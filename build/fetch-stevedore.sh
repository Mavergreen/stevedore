#!/bin/sh
# platform: macOS-only -- pkgutil --expand-full unpacks the release's pkg
#   usage: sh build/fetch-stevedore.sh
#          Prints the prefix whose bin/stevedore is the stevedore release components/stevedore/version names,
#          the packager build/package-pkg.sh packages with. That release's universal pkg is fetched once into
#          ${MAVERGREEN_PKG_CACHE:-$HOME/Library/Caches/mavergreen-pkgs}/stevedore, verified against
#          components/stevedore/sha256 (build/pin-stevedore.sh writes it), and its binary is unpacked once
#          into the build root and run to check its version. MAVERGREEN_RELEASES replaces https://github.com.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
STEVEDORE_ROOT="$(dirname "$SELF")"
. "$SELF/lib.sh"
. "$SELF/msc.sh"
. "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
V="$(tr -d ' \t\n' < "$STEVEDORE_ROOT/components/stevedore/version")"
case "$V" in ''|.|..|*[!a-zA-Z0-9._-]*) echo "fetch-stevedore: components/stevedore/version holds '$V', not a release tag" >&2; exit 2 ;; esac
sha=""
[ ! -f "$STEVEDORE_ROOT/components/stevedore/sha256" ] || sha="$(tr -d ' \t\n' < "$STEVEDORE_ROOT/components/stevedore/sha256")"
case "$sha" in ''|*[!0-9a-f]*) echo "fetch-stevedore: components/stevedore/sha256 holds no SHA-256 for stevedore $V's pkg -- write it with sh build/pin-stevedore.sh" >&2; exit 1 ;; esac
[ "${#sha}" -eq 64 ] || { echo "fetch-stevedore: components/stevedore/sha256 holds no SHA-256 for stevedore $V's pkg -- write it with sh build/pin-stevedore.sh" >&2; exit 1; }
W="$(stevedore_build_root)/stevedore-packager/$V-$sha"
if [ -x "$W/bin/stevedore" ] && [ "$("$W/bin/stevedore" --version 2>/dev/null || :)" = "stevedore $V" ]; then
  printf '%s\n' "$W"; exit 0
fi
asset="stevedore-$V.pkg"
url="${MAVERGREEN_RELEASES:-https://github.com}/Mavergreen/stevedore/releases/download/$V/$asset"
cache="${MAVERGREEN_PKG_CACHE:-$HOME/Library/Caches/mavergreen-pkgs}/stevedore/$V"
shipyard_fetch_verified "$url" "$sha" "$cache" "$asset" >&2 \
  || { echo "fetch-stevedore: could not fetch and verify $url against components/stevedore/sha256" >&2; exit 1; }
mkdir -p "$(dirname "$W")"
x="$(mktemp -d "$(dirname "$W")/.fetch.XXXXXX")"
trap 'rm -rf "$x"' EXIT
pkgutil --expand-full "$cache/$asset" "$x/pkg" >&2 || { echo "fetch-stevedore: could not expand $cache/$asset" >&2; exit 1; }
found="$(find "$x/pkg" -path '*/Payload/usr/local/mavergreen/stevedore/bin/stevedore' -type f)"
[ -n "$found" ] && [ "$(printf '%s\n' "$found" | wc -l | tr -d ' ')" -eq 1 ] \
  || { echo "fetch-stevedore: $asset does not install exactly one usr/local/mavergreen/stevedore/bin/stevedore" >&2; exit 1; }
mkdir -p "$x/out/bin"
cp "$found" "$x/out/bin/stevedore"
chmod 755 "$x/out/bin/stevedore"
got="$("$x/out/bin/stevedore" --version 2>/dev/null || :)"
[ "$got" = "stevedore $V" ] || { echo "fetch-stevedore: $asset's stevedore says '$got', not 'stevedore $V'" >&2; exit 1; }
rm -rf "$W"
mv "$x/out" "$W"
printf '%s\n' "$W"
