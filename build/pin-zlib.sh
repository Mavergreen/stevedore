#!/bin/sh
# platform: host-agnostic
#   usage: sh build/pin-zlib.sh [values | apply VERSION SHA256 | fill BASE_REF]
#          Pins the SHA-256 of zlib-<version>.tar.gz for the release components/zlib/version names. values
#          downloads the tarball from github.com/madler/zlib's release and from zlib.net and prints
#          "VERSION SHA256" once both hash the same (zlib.net keeps only its current release, so an older
#          version can be pinned only from GitHub's, and this refuses); apply writes SHA256 into
#          components/zlib/sha256 when VERSION is the checkout's; fill prints values only when
#          components/zlib/version moved since BASE_REF and the committed digest is not already that
#          release's. With no argument it runs values, then apply.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SELF")"
ver="$(tr -d ' \t\n' < "$ROOT/components/zlib/version")"
case "$ver" in ''|.|..|*[!a-zA-Z0-9._-]*) echo "pin-zlib: components/zlib/version holds '$ver', not a release" >&2; exit 2 ;; esac
pin="$ROOT/components/zlib/sha256"
valid_sha() { case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -eq 64 ]; }
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -c1-64
  else openssl dgst -sha256 < "$1" | awk '{ print $NF }'
  fi
}
values() {
  . "$SELF/msc.sh"
  . "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/pin-zlib.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  shipyard_curl "https://github.com/madler/zlib/releases/download/v$ver/zlib-$ver.tar.gz" "$tmp/github.tar.gz"
  shipyard_curl "https://zlib.net/zlib-$ver.tar.gz" "$tmp/zlib-net.tar.gz" || {
    echo "pin-zlib: zlib.net does not serve zlib-$ver.tar.gz, so there is no second source to check GitHub's against" >&2
    exit 1
  }
  a="$(sha256 "$tmp/github.tar.gz")"
  b="$(sha256 "$tmp/zlib-net.tar.gz")"
  [ "$a" = "$b" ] || { echo "pin-zlib: GitHub's zlib-$ver.tar.gz is $a but zlib.net's is $b" >&2; exit 1; }
  printf '%s %s\n' "$ver" "$a"
}
apply() {
  [ "$1" = "$ver" ] || { echo "pin-zlib: $1 is not the release components/zlib/version names ($ver)" >&2; exit 2; }
  valid_sha "$2" || { echo "pin-zlib: '$2' is not a SHA-256" >&2; exit 2; }
  printf '%s\n' "$2" > "$pin"
  echo "pin-zlib: components/zlib/sha256 = $2 (zlib $ver)" >&2
}
case "${1:-}" in
  '') [ $# -le 1 ] || exit 2; out="$(values)"; apply "${out%% *}" "${out#* }" ;;
  values) [ $# -eq 1 ] || exit 2; values ;;
  apply) [ $# -eq 3 ] || { echo 'usage: pin-zlib.sh apply VERSION SHA256' >&2; exit 2; }; apply "$2" "$3" ;;
  fill)
    [ $# -eq 2 ] || { echo 'usage: pin-zlib.sh fill BASE_REF' >&2; exit 2; }
    base_rev="$(git -C "$ROOT" merge-base "$2" HEAD)"
    [ -n "$(git -C "$ROOT" diff "$base_rev" HEAD -- components/zlib/version)" ] || exit 0
    out="$(values)"
    [ ! -f "$pin" ] || [ "$(cat "$pin")" != "${out#* }" ] || exit 0
    printf '%s\n' "$out" ;;
  *) echo 'usage: pin-zlib.sh [values | apply VERSION SHA256 | fill BASE_REF]' >&2; exit 2 ;;
esac
