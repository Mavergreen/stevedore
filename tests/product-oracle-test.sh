#!/bin/sh
# platform: macOS-only -- productbuild, pkgutil and Installer are the oracle stevedore product is checked against
#   usage: sh tests/product-oracle-test.sh
#          Runs shipyard's set_install_floor.sh with a productbuild that records the distribution.xml
#          and base component it is given, then builds the same product with stevedore product, and
#          builds the fixture product with productbuild directly. Each pair must expand to the same
#          names in the same xar order, the same encodings and the same files, and set_install_floor.sh's
#          own self-check must accept both. The Distributions are compared byte for byte except where
#          productbuild itself varies: the bundle elements' order and their attributes' order (hash
#          order, which differs between productbuild versions, so both are sorted), and updateKBytes="0",
#          which productbuild on 10.9 omits and later productbuild writes (so it is removed), and what
#          tests/fixtures/oracle/normalize.sh reconciles.
#          With passwordless sudo it then installs both fixture products, under throwaway identifiers
#          and a scratch install location instead of the real dev.mavergreen.base, compares the receipts,
#          the installed trees and the order the scripts ran in, and checks that Installer refuses both
#          under a floor above this host. Exits 77 without productbuild, and after the comparisons without sudo.
set -eu
STEVEDORE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$STEVEDORE_ROOT/build/lib.sh"
B="$(stevedore_build_dir)"
SD="${STEVEDORE:-$B/stevedore}"
FX="$STEVEDORE_ROOT/tests/fixtures"
SHIPYARD_SCRIPTS="${SHIPYARD_SCRIPTS:-/usr/local/mavergreen/shipyard/share/cmake/MavericksShipyard/scripts}"
. "$FX/trees/bundles.sh"
. "$FX/product/build.sh"
. "$FX/oracle/normalize.sh"
. "$FX/oracle/compare.sh"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

[ "$(uname -s)" = Darwin ] && PRODUCTBUILD="$(command -v productbuild 2>/dev/null)" || { echo "product-oracle-test: SKIP (no productbuild)"; exit 77; }
SIF="$SHIPYARD_SCRIPTS/set_install_floor.sh"
[ -f "$SIF" ] || { echo "product-oracle-test: SKIP (no set_install_floor.sh in $SHIPYARD_SCRIPTS)"; exit 77; }
[ -x "$SD" ] || { echo "FAIL: no stevedore binary at $SD -- build it with sh build/build.sh, or set STEVEDORE" >&2; exit 1; }
sudo=0
sudo -n true 2>/dev/null && sudo=1

T="$(mktemp -d "${TMPDIR:-/tmp}/product-oracle.XXXXXX")"
S="$(mktemp -d /private/tmp/stevedore-product.XXXXXX)"
BASEID="dev.mavergreen.stevedore-test.$$.base"
PRODID="dev.mavergreen.stevedore-test.$$.product"
cleanup() {
  if [ "$sudo" -eq 1 ]; then
    for id in "$BASEID" "$PRODID"; do sudo -n pkgutil --forget "$id" >/dev/null 2>&1 || :; done
    sudo -n rm -rf "$S"
  fi
  rm -rf "$S" 2>/dev/null || :
  chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"
}
trap cleanup EXIT
MT=1672574400

sed -n '/^X=\$(mktemp -d -t pkgfloor/,/the conclusion pane did not make it/p' "$SIF" > "$T/selfcheck.sh"
grep -q 'FLOOR MISSING' "$T/selfcheck.sh" && grep -q 'is not first' "$T/selfcheck.sh" \
  || fail "set_install_floor.sh's self-check is no longer where this test extracts it from"
selfcheck() {
  OUT="$1" MIN_OS="$2" CONCLUSION="$3" sh -eu "$T/selfcheck.sh" >/dev/null 2>"$T/selfcheck.err" \
    || fail "set_install_floor.sh's self-check rejects $1: $(tr '\n' '|' < "$T/selfcheck.err")"
}

mkdir "$T/s" "$T/shim" "$T/cap" "$T/sifc"
product_inputs "$SD" "$T/s" || fail "stevedore component of the fixture inputs exited $?"
cp "$T/s/pkgs/product.pkg" "$T/sifc/"
cat > "$T/shim/productbuild" <<EOF
#!/bin/sh
prev=""
for a in "\$@"; do
  case "\$prev" in
    --distribution) cp "\$a" "$T/cap/distribution.xml" ;;
    --package-path) [ ! -f "\$a/mavergreen-base.pkg" ] || cp "\$a/mavergreen-base.pkg" "$T/cap/" ;;
  esac
  prev="\$a"
done
exec "$PRODUCTBUILD" "\$@"
EOF
chmod 755 "$T/shim/productbuild"
PATH="$T/shim:$PATH" sh "$SIF" --identifier dev.mavergreen.stevedore-test.product --title "Stevedore Test" \
  --component "$T/sifc/product.pkg" --out "$T/sif.pb.pkg" --resources "$T/s/res" --welcome welcome.html \
  --license license.txt --conclusion conclusion.html --require-scripts --host-arch x86_64 --min-os 10.9.5 \
  --base-version 1.0.5 >/dev/null 2>"$T/sif.err" || fail "set_install_floor.sh failed: $(tr '\n' '|' < "$T/sif.err")"
if [ -f "$T/cap/distribution.xml" ] && [ -f "$T/cap/mavergreen-base.pkg" ]; then
  cmp -s "$T/cap/distribution.xml" "$FX/product/distribution.xml" \
    || fail "set_install_floor.sh no longer writes tests/fixtures/product/distribution.xml: $(diff "$FX/product/distribution.xml" "$T/cap/distribution.xml" | tr '\n' '|')"
  "$SD" product --distribution "$T/cap/distribution.xml" --package "$T/cap/mavergreen-base.pkg" --package "$T/sifc/product.pkg" \
    --resources "$T/s/res" --mtime "$MT" --out "$T/sif.sd.pkg" || fail "stevedore product of set_install_floor.sh's inputs exited $?"
  [ -f "$T/sif.sd.pkg" ] && same_products "set_install_floor.sh" "$T/sif.pb.pkg" "$T/sif.sd.pkg" || :
  selfcheck "$T/sif.pb.pkg" 10.9.5 conclusion.html
  selfcheck "$T/sif.sd.pkg" 10.9.5 conclusion.html
else
  fail "the productbuild shim saw no distribution.xml or no mavergreen-base.pkg"
fi

"$PRODUCTBUILD" --distribution "$T/s/distribution.xml" --resources "$T/s/res" --package-path "$T/s/pkgs" "$T/fx.pb.pkg" >/dev/null \
  || fail "productbuild of the fixture failed"
product_fixture "$SD" "$T/s" "$T/fx.sd.pkg" || fail "stevedore product of the fixture exited $?"
if [ -f "$T/fx.pb.pkg" ] && [ -f "$T/fx.sd.pkg" ]; then
  same_products fixture "$T/fx.pb.pkg" "$T/fx.sd.pkg" || :
  cmp -s "$T/sd.x/Distribution" "$FX/product/Distribution" || fail "the fixture's Distribution is not tests/fixtures/product/Distribution"
  oracle_reconcile "$T/pb.x/Distribution" "$FX/product/Distribution" "$T/pb.dist" "$T/fx.dist"
  canon "$T/fx.dist" | cmp -s - "$T/pb.canon" || fail "tests/fixtures/product/Distribution is not productbuild's beyond bundle order, updateKBytes and oracle_reconcile"
fi

[ "$sudo" -eq 1 ] || {
  [ "$fails" -eq 0 ] || { echo "product-oracle-test: $fails failure(s)" >&2; exit 1; }
  echo "product-oracle-test: SKIP the install comparison (no passwordless sudo)"; exit 77
}

mkdir "$T/i"
product_inputs "$SD" "$T/i" "$BASEID" "$PRODID" "$S" || fail "stevedore component of the install inputs exited $?"
"$PRODUCTBUILD" --distribution "$T/i/distribution.xml" --resources "$T/i/res" --package-path "$T/i/pkgs" "$T/i.pb.pkg" >/dev/null \
  || fail "productbuild of the install inputs failed"
product_fixture "$SD" "$T/i" "$T/i.sd.pkg" || fail "stevedore product of the install inputs exited $?"

installed() {
  sudo -n installer -pkg "$T/i.$1.pkg" -target / >"$T/install.out" 2>&1 \
    || { fail "installer rejects the $1 product: $(tr '\n' '|' < "$T/install.out")"; return 1; }
  {
    for id in "$BASEID" "$PRODID"; do
      echo "== pkg-info $id"; pkgutil --pkg-info "$id" | grep -v '^install-time:'
      echo "== files $id"; pkgutil --files "$id"
      echo "== receipt $id"; TZ=UTC lsbom -p MUGsTfc "/var/db/receipts/$id.bom"
    done
    for k in base product; do
      echo "== tree $k"; (cd "$S/$k" && sudo -n find . -exec stat -f '%Sp %Su %Sg %z %m %N%SY' {} + | awk -v mt="$MT" '$5 != mt { $5 = "install-time" } { print }' | LC_ALL=C sort)
      echo "== contents $k"; (cd "$S/$k" && sudo -n find . -type f -exec cksum {} + | LC_ALL=C sort)
    done
    echo "== order"; cat "$S/order"
  } > "$T/$1.installed" 2>&1
  b="$(grep -n '^base postinstall$' "$S/order" | cut -d: -f1)"
  p="$(grep -n '^product postinstall$' "$S/order" | cut -d: -f1)"
  [ -n "$b" ] && [ -n "$p" ] && [ "$b" -lt "$p" ] || fail "the $1 product did not run the base's postinstall before the product's: $(tr '\n' '|' < "$S/order")"
  for id in "$BASEID" "$PRODID"; do sudo -n pkgutil --forget "$id" >/dev/null; done
  sudo -n rm -rf "$S/base" "$S/product" "$S/order"
}
if [ -f "$T/i.pb.pkg" ] && [ -f "$T/i.sd.pkg" ] && installed pb && installed sd; then
  cmp -s "$T/pb.installed" "$T/sd.installed" \
    || fail "the installs differ: $(diff "$T/pb.installed" "$T/sd.installed" | head -12 | tr '\n' '|')"
fi

host="$(sw_vers -productVersion)"
case "$host" in 10.9|10.9.*) floor=10.10 ;; *) floor=99.0 ;; esac
"$PRODUCTBUILD" --distribution "$(sed "s/os-version min=\"[^\"]*\"/os-version min=\"$floor\"/" "$T/i/distribution.xml" > "$T/i/floor.xml"; echo "$T/i/floor.xml")" \
  --resources "$T/i/res" --package-path "$T/i/pkgs" "$T/floor.pb.pkg" >/dev/null || fail "productbuild of the floor $floor product failed"
product_fixture "$SD" "$T/i" "$T/floor.sd.pkg" "$floor" || fail "stevedore product with floor $floor exited $?"
for k in pb sd; do
  [ -f "$T/floor.$k.pkg" ] || continue
  if sudo -n installer -pkg "$T/floor.$k.pkg" -target / >"$T/floor.out" 2>&1; then
    fail "Installer on $host installed the $k product whose floor is $floor"
  fi
  for id in "$BASEID" "$PRODID"; do
    ! pkgutil --pkg-info "$id" >/dev/null 2>&1 || fail "the refused $k product left a receipt for $id"
  done
  [ ! -e "$S/base" ] && [ ! -e "$S/product" ] && [ ! -e "$S/order" ] || fail "the refused $k product installed something under $S"
  for id in "$BASEID" "$PRODID"; do sudo -n pkgutil --forget "$id" >/dev/null 2>&1 || :; done
  sudo -n rm -rf "$S/base" "$S/product" "$S/order"
done

[ "$fails" -eq 0 ] || { echo "product-oracle-test: $fails failure(s)" >&2; exit 1; }
echo "product-oracle-test: ok (host $host, refused floor $floor)"
