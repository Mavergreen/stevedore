#!/bin/sh
# platform: host-agnostic
#   usage: sh build/pin-clang22.sh [values | apply VERSION SHA256 | fill BASE_REF]
#          Pins the SHA-256 of clang22's linux-x86_64 archive for the release components/clang22/version
#          names. values downloads the archive, checks it against the SHA256SUMS that release publishes and
#          prints "VERSION SHA256"; apply writes SHA256 into components/clang22/sha256 when VERSION is the
#          checkout's; fill prints values only when components/clang22/version moved since BASE_REF and the
#          committed digest is not already that release's. With no argument it runs values, then apply.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SELF")"
STEVEDORE_ROOT="$ROOT"
. "$SELF/lib.sh"
V="$(tr -d ' \t\n' < "$ROOT/components/clang22/version")"
case "$V" in ''|.|..|*[!a-zA-Z0-9._-]*) echo "pin-clang22: components/clang22/version holds '$V', not a release tag" >&2; exit 2 ;; esac
asset="clang22-$V-linux-x86_64.tar.gz"
pin="$ROOT/components/clang22/sha256"
valid_sha() { case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -eq 64 ]; }
values() {
  . "$SELF/msc.sh"
  . "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
  base="${MAVERGREEN_RELEASES:-https://github.com}/Mavergreen/clang-22/releases/download/$V"
  sums="$(shipyard_curl "$base/SHA256SUMS" -)" || { echo "pin-clang22: could not read clang22 $V's SHA256SUMS" >&2; exit 1; }
  sha="$(printf '%s\n' "$sums" | awk -v a="$asset" '$2 == a || $2 == "*" a { print $1 }')"
  valid_sha "$sha" || { echo "pin-clang22: clang22 $V's SHA256SUMS lists no single digest for $asset" >&2; exit 1; }
  shipyard_fetch_verified "$base/$asset" "$sha" "$(stevedore_build_root)/clang22-pin/$V" "$asset"
  printf '%s %s\n' "$V" "$sha"
}
apply() {
  [ "$1" = "$V" ] || { echo "pin-clang22: $1 is not the release components/clang22/version names ($V)" >&2; exit 2; }
  valid_sha "$2" || { echo "pin-clang22: '$2' is not a SHA-256" >&2; exit 2; }
  printf '%s\n' "$2" > "$pin"
  echo "pin-clang22: components/clang22/sha256 = $2 (clang22 $V)" >&2
}
case "${1:-}" in
  '') [ $# -le 1 ] || exit 2; out="$(values)"; apply "${out%% *}" "${out#* }" ;;
  values) [ $# -eq 1 ] || exit 2; values ;;
  apply) [ $# -eq 3 ] || { echo 'usage: pin-clang22.sh apply VERSION SHA256' >&2; exit 2; }; apply "$2" "$3" ;;
  fill)
    [ $# -eq 2 ] || { echo 'usage: pin-clang22.sh fill BASE_REF' >&2; exit 2; }
    base_rev="$(git -C "$ROOT" merge-base "$2" HEAD)"
    [ -n "$(git -C "$ROOT" diff "$base_rev" HEAD -- components/clang22/version)" ] || exit 0
    out="$(values)"
    [ ! -f "$pin" ] || [ "$(cat "$pin")" != "${out#* }" ] || exit 0
    printf '%s\n' "$out" ;;
  *) echo 'usage: pin-clang22.sh [values | apply VERSION SHA256 | fill BASE_REF]' >&2; exit 2 ;;
esac
