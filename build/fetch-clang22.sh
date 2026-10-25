#!/bin/sh
# platform: host-agnostic
#   usage: sh build/fetch-clang22.sh
#          Prints the prefix of the clang22 release components/clang22/version names, for this host and
#          ARCH. On Linux: that release's linux-x86_64 archive, verified against components/clang22/sha256
#          (build/pin-clang22.sh writes it) and unpacked once into the build root. On a Mac building x86_64: the installed
#          /usr/local/mavergreen/clang22 (CLANG22_INSTALLED moves it) when its manifest names that release;
#          otherwise, and for arm64, that release's clang22-cross pkg, fetched once into the build root.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
STEVEDORE_ROOT="$(dirname "$SELF")"
. "$SELF/lib.sh"
. "$SELF/msc.sh"
V="$(tr -d ' \t\n' < "$STEVEDORE_ROOT/components/clang22/version")"
case "$V" in ''|.|..|*[!a-zA-Z0-9._-]*) echo "fetch-clang22: components/clang22/version holds '$V', not a release tag" >&2; exit 2 ;; esac
W="$(stevedore_build_root)/clang22/$V"
has_tools() {
  for t in clang llvm-ar llvm-ranlib llvm-otool llvm-lipo llvm-nm llvm-strings; do [ -x "$1/bin/$t" ] || return 1; done
}
case "$(uname -s)" in
  Linux)
    [ "$(stevedore_arch)" = x86_64 ] || { echo "fetch-clang22: clang22 publishes a Linux archive for x86_64 hosts only, not $(stevedore_arch)" >&2; exit 2; }
    sha=""
    [ ! -f "$STEVEDORE_ROOT/components/clang22/sha256" ] || sha="$(tr -d ' \t\n' < "$STEVEDORE_ROOT/components/clang22/sha256")"
    case "$sha" in ''|*[!0-9a-f]*) echo "fetch-clang22: components/clang22/sha256 holds no SHA-256 for clang22 $V's Linux archive -- write it with sh build/pin-clang22.sh" >&2; exit 1 ;; esac
    [ "${#sha}" -eq 64 ] || { echo "fetch-clang22: components/clang22/sha256 holds no SHA-256 for clang22 $V's Linux archive -- write it with sh build/pin-clang22.sh" >&2; exit 1; }
    d="$W/linux"
    sh "$SHIPYARD_SCRIPTS/fetch_product_tar.sh" clang22 "$V" "$sha" "$d" >/dev/null ;;
  Darwin)
    inst="${CLANG22_INSTALLED:-/usr/local/mavergreen/clang22}"
    if [ "$(stevedore_arch)" = x86_64 ] && has_tools "$inst" \
       && grep -A1 '<key>version</key>' "$inst/mavergreen.plist" 2>/dev/null | grep -q "<string>$V</string>"; then
      printf '%s\n' "$inst"; exit 0
    fi
    d="$W/cross"
    sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" --asset "mavericks-clang-22-cross-$V.pkg" clang22-cross "$V" "$d" >/dev/null ;;
  *) echo "fetch-clang22: clang22 builds stevedore on Linux and on a Mac, not on $(uname -s)" >&2; exit 2 ;;
esac
has_tools "$d" || { echo "fetch-clang22: $d lacks clang or one of llvm-{ar,ranlib,otool,lipo,nm,strings}" >&2; exit 1; }
printf '%s\n' "$d"
