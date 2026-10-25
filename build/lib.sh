#!/bin/sh
# platform: host-agnostic
: "${STEVEDORE_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"

stevedore_arch() {
  if [ -n "${ARCH:-}" ]; then printf '%s\n' "$ARCH"
  elif [ "$(uname -s)" = Darwin ]; then echo x86_64
  else uname -m
  fi
}

stevedore_build_dir() {
  _os="$(uname -s | tr 'A-Z' 'a-z')"
  _tmp="${TMPDIR:-/tmp}"
  _root="${MAVERICKS_BUILD_ROOT:-${_tmp%/}/mm-build}"
  printf '%s\n' "${STEVEDORE_BUILD:-${_root%/}/$(basename "$STEVEDORE_ROOT")-$_os-$(stevedore_arch)}"
}
