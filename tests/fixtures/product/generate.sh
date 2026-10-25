#!/bin/sh
# platform: host-agnostic
#   usage: sh tests/fixtures/product/generate.sh
#          Writes product.sha256 and Distribution here for the fixture product, as stevedore-golden
#          builds it. Regenerate only after tests/product-oracle-test.sh passes on Mac OS X 10.9, and
#          say so in the commit.
set -eu
FX="$(cd "$(dirname "$0")/.." && pwd)"
STEVEDORE_ROOT="$(cd "$FX/../.." && pwd)"
. "$STEVEDORE_ROOT/build/lib.sh"
GOLDEN="${STEVEDORE_GOLDEN:-$(stevedore_build_dir)/stevedore-golden}"
. "$FX/trees/bundles.sh"
. "$FX/product/build.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/product-generate.XXXXXX")"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
product_inputs "$GOLDEN" "$T"
product_fixture "$GOLDEN" "$T" "$T/product.pkg"
if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$T/product.pkg" | cut -c1-64 > "$FX/product/product.sha256"
else openssl dgst -sha256 < "$T/product.pkg" | awk '{ print $NF }' > "$FX/product/product.sha256"
fi
"$GOLDEN" expand "$T/product.pkg" "$T/x"
cp "$T/x/Distribution" "$FX/product/Distribution"
