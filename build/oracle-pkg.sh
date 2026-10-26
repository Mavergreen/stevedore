#!/bin/sh
# platform: macOS-only -- pkgbuild, productbuild, pkgutil and xar write and read the pkgs it compares
#   usage: sh build/oracle-pkg.sh WORK PKG MTIME VERSION
#          WORK is build/package-pkg.sh's scratch directory (root, scripts, distribution.xml)
#          and PKG the product stevedore wrote from it. Stamps WORK's trees with MTIME, builds both components
#          the stevedore component with shipyard's build_component_pkg.sh (pkgbuild), the base component with
#          shipyard's own build-base-component.sh (its staging and pkgbuild, whose inputs are stamped MTIME), the product with productbuild from the same
#          distribution.xml, and fails unless PKG is the same pkg beyond what tests/fixtures/oracle reconciles.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
STEVEDORE_ROOT="$(dirname "$SELF")"
. "$SELF/msc.sh"
[ $# -eq 4 ] || { echo "usage: sh build/oracle-pkg.sh WORK PKG MTIME VERSION" >&2; exit 2; }
WORK="$1"; PKG="$2"; MT="$3"; VER="$4"
FX="$STEVEDORE_ROOT/tests/fixtures"
. "$FX/oracle/normalize.sh"
. "$FX/oracle/compare.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/oracle-pkg.XXXXXX")"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
stamp="$(date -u -r "$MT" +%Y%m%d%H%M.%S)"
find "$WORK/root" "$WORK/scripts" -exec env TZ=UTC touch -h -t "$stamp" {} +
mkdir "$T/pkgs"
mkdir "$T/shim"
REALPKGBUILD="$(command -v pkgbuild)"
cat > "$T/shim/pkgbuild" <<SHIM
#!/bin/sh
prev=""
for a in "\$@"; do
  case "\$prev" in --root|--scripts) find "\$a" -exec env TZ=UTC touch -h -t "$stamp" {} + ;; esac
  prev="\$a"
done
exec "$REALPKGBUILD" "\$@"
SHIM
chmod 755 "$T/shim/pkgbuild"
PATH="$T/shim:$PATH" sh "$SHIPYARD_SCRIPTS/build-base-component.sh" --out "$T/pkgs/mavergreen-base.pkg" >/dev/null
sh "$SHIPYARD_SCRIPTS/build_component_pkg.sh" --root "$WORK/root" --identifier dev.mavergreen.stevedore --version "$VER" \
  --install-location / --scripts "$WORK/scripts" --out "$T/pkgs/stevedore.pkg" >/dev/null
productbuild --distribution "$WORK/distribution.xml" --package-path "$T/pkgs" "$T/pb.pkg" >/dev/null
SAME_COMPONENTS=1 same_products "the release pkg" "$T/pb.pkg" "$PKG" || :
[ "$fails" -eq 0 ] || { echo "oracle-pkg: $PKG is not what pkgbuild and productbuild write from the same inputs ($fails difference(s))" >&2; exit 1; }
echo "oracle-pkg: $PKG matches pkgbuild and productbuild" >&2
