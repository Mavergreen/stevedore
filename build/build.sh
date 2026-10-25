#!/bin/sh
# platform: host-agnostic
#   usage: sh build/build.sh
#          Configures and builds stevedore out of the tree, in the directory build/lib.sh's
#          stevedore_build_dir names, and prints it. STEVEDORE_TARGET picks what it runs on: darwin (the
#          default on a Mac) or linux (the default on Linux); a Linux host builds either, a Mac only darwin.
#          A darwin build targets the family's pinned SDK for ARCH (x86_64, the default, or arm64, on a
#          Mac only) through MavericksToolchain.cmake. The compiler is the clang22 build/fetch-clang22.sh
#          prints, unless CC names another; CMAKE overrides the cmake (default: shipyard-cmake on a Mac,
#          the host's cmake on Linux).
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
STEVEDORE_ROOT="$(dirname "$SELF")"
. "$SELF/lib.sh"
. "$SELF/msc.sh"
B="$(stevedore_build_dir)"
host="$(uname -s)"
target="$(stevedore_target)"
arch="$(stevedore_arch)"
case "$host:$target" in
  Darwin:darwin|Linux:darwin|Linux:linux) : ;;
  *) echo "build: a $host host does not build a $target stevedore" >&2; exit 2 ;;
esac
if [ "$host" = Linux ]; then
  CMAKE="${CMAKE:-$(command -v cmake || echo cmake)}"
else
  CMAKE="${CMAKE:-$(command -v shipyard-cmake || echo /usr/local/mavergreen/bin/shipyard-cmake)}"
fi
CL=""
[ -n "${CC:-}" ] || { CL="$(sh "$SELF/fetch-clang22.sh")"; CC="$CL/bin/clang"; }
set -- -S "$STEVEDORE_ROOT" -B "$B" -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$CC"
if [ -n "$CL" ]; then
  set -- "$@" -DCMAKE_AR="$CL/bin/llvm-ar" -DCMAKE_RANLIB="$CL/bin/llvm-ranlib"
  LIPO="$CL/bin/llvm-lipo"; OTOOL="$CL/bin/llvm-otool"; NM="$CL/bin/llvm-nm"; STRINGS="$CL/bin/llvm-strings"
  export LIPO OTOOL NM STRINGS
fi
if [ "$target" = darwin ]; then
  set -- "$@" -DCMAKE_TOOLCHAIN_FILE="$SHIPYARD_SCRIPTS/../MavericksToolchain.cmake" -DCMAKE_OSX_ARCHITECTURES="$arch"
  if [ "$host" = Linux ] && [ -n "$CL" ]; then
    "$CL/bin/setup-sdk" "$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")" >&2
    set -- "$@" -DCMAKE_INSTALL_NAME_TOOL="$CL/bin/llvm-install-name-tool" -DCMAKE_STRIP="$CL/bin/llvm-strip"
  fi
  # platform: clang22-cross's clang.cfg is x86_64 10.9's: its --target, its sysroot and librecaulk.a
  if [ "$arch" = arm64 ] && [ -n "$CL" ]; then
    set -- "$@" -DCMAKE_C_FLAGS=--no-default-config -DCMAKE_EXE_LINKER_FLAGS="--ld-path=$CL/bin/ld64.lld"
  fi
elif [ -n "$CL" ]; then
  # platform: clang22's clang.cfg targets Mavericks, and the only compiler-rt it carries is Darwin's
  set -- "$@" -DCMAKE_C_FLAGS="--no-default-config --target=x86_64-linux-gnu --rtlib=libgcc -fuse-ld=lld"
fi
"$CMAKE" "$@" 1>&2
"$CMAKE" --build "$B" 1>&2
printf '%s\n' "$B"
