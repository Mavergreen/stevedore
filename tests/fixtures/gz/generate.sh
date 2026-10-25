#!/bin/sh
# platform: host-agnostic
#   usage: STEVEDORE=<binary> sh tests/fixtures/gz/generate.sh
#          Rewrites the .gz and .zz fixtures here from the inputs inputs.sh builds, with the stevedore
#          given. The fixtures are the cross-host oracle: regenerate them only when the zlib pin moves on
#          purpose, and say so in the commit.
set -eu
FX="$(cd "$(dirname "$0")" && pwd)"
SD="${STEVEDORE:?set STEVEDORE to the stevedore binary}"
. "$FX/inputs.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/gz-generate.XXXXXX")"
trap 'rm -rf "$T"' EXIT
gz_inputs "$FX" "$T"
for name in empty one-byte random-1mib toc-text; do "$SD" gzip < "$T/$name" > "$FX/$name.gz"; done
for name in empty one-byte toc-text; do "$SD" zlib < "$T/$name" > "$FX/$name.zz"; done
