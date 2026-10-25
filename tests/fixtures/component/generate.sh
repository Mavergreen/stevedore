#!/bin/sh
# platform: host-agnostic
#   usage: sh tests/fixtures/component/generate.sh
#          Writes NAME.sha256 and NAME.PackageInfo here for the basic tree (with the scripts
#          directory) and the bundles tree, as stevedore-golden (generator-version "0-golden") packages
#          them. Regenerate only after tests/component-oracle-test.sh passes on Mac OS X 10.9, and say
#          so in the commit.
set -eu
FX="$(cd "$(dirname "$0")/.." && pwd)"
STEVEDORE_ROOT="$(cd "$FX/../.." && pwd)"
. "$STEVEDORE_ROOT/build/lib.sh"
GOLDEN="${STEVEDORE_GOLDEN:-$(stevedore_build_dir)/stevedore-golden}"
. "$FX/trees/basic.sh"
. "$FX/trees/bundles.sh"
. "$FX/trees/scripts.sh"
. "$FX/component/build.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/component-generate.XXXXXX")"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
component_fixtures "$T"
for name in basic bundles; do
  component_fixture "$GOLDEN" "$T" "$name" "$T/$name.pkg"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$T/$name.pkg" | cut -c1-64 > "$FX/component/$name.sha256"
  else openssl dgst -sha256 < "$T/$name.pkg" | awk '{ print $NF }' > "$FX/component/$name.sha256"
  fi
  "$GOLDEN" expand "$T/$name.pkg" "$T/$name.x"
  cp "$T/$name.x/PackageInfo" "$FX/component/$name.PackageInfo"
done
