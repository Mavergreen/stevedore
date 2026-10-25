#!/bin/sh
# platform: host-agnostic
#   usage: sh build/build.sh
#          Configures and builds stevedore out of the tree, in the directory build/lib.sh's
#          stevedore_build_dir names, and prints it. On a Mac the build targets the family's pinned SDK
#          for ARCH (x86_64, the default, or arm64) through MavericksToolchain.cmake; on Linux it is a
#          native build. CC overrides the compiler (default: clang22's); CMAKE overrides the cmake
#          (default: shipyard-cmake).
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
STEVEDORE_ROOT="$(dirname "$SELF")"
. "$SELF/lib.sh"
. "$SELF/msc.sh"
B="$(stevedore_build_dir)"
CMAKE="${CMAKE:-$(command -v shipyard-cmake || echo /usr/local/mavergreen/bin/shipyard-cmake)}"
set -- -S "$STEVEDORE_ROOT" -B "$B" -DCMAKE_BUILD_TYPE=Release
if [ "$(uname -s)" = Darwin ]; then
  set -- "$@" -DCMAKE_TOOLCHAIN_FILE="$SHIPYARD_SCRIPTS/../MavericksToolchain.cmake" \
    -DCMAKE_OSX_ARCHITECTURES="$(stevedore_arch)" \
    -DCMAKE_C_COMPILER="${CC:-/usr/local/mavergreen/clang22/bin/clang}"
elif [ -n "${CC:-}" ]; then
  set -- "$@" -DCMAKE_C_COMPILER="$CC"
fi
"$CMAKE" "$@" 1>&2
"$CMAKE" --build "$B" 1>&2
printf '%s\n' "$B"
