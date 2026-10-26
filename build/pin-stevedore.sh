#!/bin/sh
# platform: host-agnostic
#   usage: sh build/pin-stevedore.sh [values | apply VERSION SHA256]
#          Pins the SHA-256 of the pkg of the stevedore release components/stevedore/version names, which
#          packages stevedore's own releases. values downloads the pkg, checks it against the SHA256SUMS that
#          release publishes and prints "VERSION SHA256"; apply writes SHA256 into components/stevedore/sha256
#          when VERSION is the checkout's. With no argument it runs values, then apply. No bot runs it: this
#          pin is bumped by hand.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SELF")"
STEVEDORE_ROOT="$ROOT"
. "$SELF/lib.sh"
V="$(tr -d ' \t\n' < "$ROOT/components/stevedore/version")"
case "$V" in ''|.|..|*[!a-zA-Z0-9._-]*) echo "pin-stevedore: components/stevedore/version holds '$V', not a release tag" >&2; exit 2 ;; esac
asset="stevedore-$V.pkg"
pin="$ROOT/components/stevedore/sha256"
valid_sha() { case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -eq 64 ]; }
values() {
  . "$SELF/msc.sh"
  . "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
  base="${MAVERGREEN_RELEASES:-https://github.com}/Mavergreen/stevedore/releases/download/$V"
  sums="$(shipyard_curl "$base/SHA256SUMS" -)" || { echo "pin-stevedore: could not read stevedore $V's SHA256SUMS" >&2; exit 1; }
  sha="$(printf '%s\n' "$sums" | awk -v a="$asset" '$2 == a || $2 == "*" a { print $1 }')"
  valid_sha "$sha" || { echo "pin-stevedore: stevedore $V's SHA256SUMS lists no single digest for $asset" >&2; exit 1; }
  shipyard_fetch_verified "$base/$asset" "$sha" "$(stevedore_build_root)/stevedore-pin/$V" "$asset" >&2
  printf '%s %s\n' "$V" "$sha"
}
apply() {
  [ "$1" = "$V" ] || { echo "pin-stevedore: $1 is not the release components/stevedore/version names ($V)" >&2; exit 2; }
  valid_sha "$2" || { echo "pin-stevedore: '$2' is not a SHA-256" >&2; exit 2; }
  printf '%s\n' "$2" > "$pin"
  echo "pin-stevedore: components/stevedore/sha256 = $2 (stevedore $V)" >&2
}
case "${1:-}" in
  '') [ $# -le 1 ] || exit 2; out="$(values)"; apply "${out%% *}" "${out#* }" ;;
  values) [ $# -eq 1 ] || exit 2; values ;;
  apply) [ $# -eq 3 ] || { echo 'usage: pin-stevedore.sh apply VERSION SHA256' >&2; exit 2; }; apply "$2" "$3" ;;
  *) echo 'usage: pin-stevedore.sh [values | apply VERSION SHA256]' >&2; exit 2 ;;
esac
