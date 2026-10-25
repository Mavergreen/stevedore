#!/bin/sh
# platform: host-agnostic
: "${STEVEDORE_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"

stevedore_arch() {
  if [ -n "${ARCH:-}" ]; then printf '%s\n' "$ARCH"
  elif [ "$(uname -s)" = Darwin ]; then echo x86_64
  else uname -m
  fi
}

stevedore_target() {
  printf '%s\n' "${STEVEDORE_TARGET:-$(uname -s | tr 'A-Z' 'a-z')}"
}

stevedore_build_root() {
  _tmp="${TMPDIR:-/tmp}"
  _root="${MAVERICKS_BUILD_ROOT:-${_tmp%/}/mm-build}"
  printf '%s\n' "${_root%/}"
}

stevedore_build_dir() {
  printf '%s\n' "${STEVEDORE_BUILD:-$(stevedore_build_root)/$(basename "$STEVEDORE_ROOT")-$(stevedore_target)-$(stevedore_arch)}"
}
