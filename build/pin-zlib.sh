#!/bin/sh
# platform: host-agnostic
#   usage: sh build/pin-zlib.sh
#          Writes components/zlib/sha256 for the release components/zlib/version names, after the tarball
#          from github.com/madler/zlib's release and the one from zlib.net hash the same. zlib.net keeps only
#          its current release, so an older version can be pinned only from GitHub's, and this refuses.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SELF")"
. "$SELF/msc.sh"
. "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
ver="$(cat "$ROOT/components/zlib/version")"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/pin-zlib.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -c1-64
  else openssl dgst -sha256 < "$1" | awk '{ print $NF }'
  fi
}
shipyard_curl "https://github.com/madler/zlib/releases/download/v$ver/zlib-$ver.tar.gz" "$tmp/github.tar.gz"
shipyard_curl "https://zlib.net/zlib-$ver.tar.gz" "$tmp/zlib-net.tar.gz" || {
  echo "pin-zlib: zlib.net does not serve zlib-$ver.tar.gz, so there is no second source to check GitHub's against" >&2
  exit 1
}
a="$(sha256 "$tmp/github.tar.gz")"
b="$(sha256 "$tmp/zlib-net.tar.gz")"
[ "$a" = "$b" ] || { echo "pin-zlib: GitHub's zlib-$ver.tar.gz is $a but zlib.net's is $b" >&2; exit 1; }
printf '%s\n' "$a" > "$ROOT/components/zlib/sha256"
echo "pin-zlib: components/zlib/sha256 = $a (zlib $ver, GitHub and zlib.net agree)" >&2
