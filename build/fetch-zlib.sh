#!/bin/sh
# platform: host-agnostic
#   usage: sh build/fetch-zlib.sh DEST
#          Replaces DEST with a fresh extraction of the zlib release pinned by components/zlib/version
#          and components/zlib/sha256. The tarball is cached in
#          ${MAVERICKS_SOURCE_CACHE:-$HOME/Library/Caches/mavericks-sources} and verified there, so a
#          second run needs no network. ZLIB_RELEASES replaces https://github.com/madler/zlib/releases/download.
set -eu
[ $# -eq 1 ] || { echo "usage: sh build/fetch-zlib.sh DEST" >&2; exit 2; }
DEST="$1"
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SELF")"
. "$SELF/msc.sh"
. "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
ver="$(cat "$ROOT/components/zlib/version")"
sha="$(cat "$ROOT/components/zlib/sha256")"
tarball="zlib-$ver.tar.gz"
url="${ZLIB_RELEASES:-https://github.com/madler/zlib/releases/download}/v$ver/$tarball"
cache="${MAVERICKS_SOURCE_CACHE:-$HOME/Library/Caches/mavericks-sources}"
x="$(shipyard_fetch_extract "$url" "$sha" "$cache" "$tarball")" || {
  echo "fetch-zlib: could not fetch and verify $url against components/zlib/sha256 -- if components/zlib/version moved, run sh build/pin-zlib.sh" >&2
  exit 1
}
[ -f "$x/zlib-$ver/zlib.h" ] || { rm -rf "$x"; echo "fetch-zlib: $tarball holds no zlib-$ver/zlib.h" >&2; exit 1; }
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$x/zlib-$ver" "$DEST"
rm -rf "$x"
printf '%s\n' "$DEST"
