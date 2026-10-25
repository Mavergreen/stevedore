#!/bin/sh
# platform: host-agnostic
set -eu
STEVEDORE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$STEVEDORE_ROOT/build/lib.sh"
B="$(stevedore_build_dir)"
SD="${STEVEDORE:-$B/stevedore}"
GOLDEN="${STEVEDORE_GOLDEN:-$B/stevedore-golden}"
FX="$STEVEDORE_ROOT/tests/fixtures"
. "$FX/trees/bundles.sh"
. "$FX/product/build.sh"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -c1-64
  else openssl dgst -sha256 < "$1" | awk '{ print $NF }'
  fi
}

[ -x "$SD" ] || { echo "FAIL: no stevedore binary at $SD -- build it with sh build/build.sh, or set STEVEDORE" >&2; exit 1; }
[ -x "$GOLDEN" ] || { echo "FAIL: no stevedore-golden binary at $GOLDEN -- the build makes it beside stevedore, or set STEVEDORE_GOLDEN" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/product-test.XXXXXX")"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
MT=1672574400

same_tree() {
  (cd "$1" && find . | LC_ALL=C sort) > "$T/a.list"
  (cd "$2" && find . | LC_ALL=C sort) > "$T/b.list"
  cmp -s "$T/a.list" "$T/b.list" || { fail "$3: names differ: $(diff "$T/a.list" "$T/b.list" | head -6 | tr '\n' '|')"; return; }
  while IFS= read -r p; do
    [ "$p" = . ] || [ "$(ls -ld "$1/$p" | cut -c1-10)" = "$(ls -ld "$2/$p" | cut -c1-10)" ] || fail "$3: $p has another mode"
    [ -f "$1/$p" ] && ! [ -h "$1/$p" ] || continue
    cmp -s "$1/$p" "$2/$p" || fail "$3: $p differs"
  done < "$T/a.list"
}

mkdir "$T/g" "$T/s"
product_inputs "$GOLDEN" "$T/g" || fail "stevedore-golden component of the product fixture inputs exited $?"
product_inputs "$SD" "$T/s" || fail "stevedore component of the product fixture inputs exited $?"

if [ ! -f "$FX/product/product.sha256" ]; then
  fail "no golden at tests/fixtures/product/product.sha256 -- write it with tests/fixtures/product/generate.sh"
elif product_fixture "$GOLDEN" "$T/g" "$T/golden.pkg"; then
  [ "$(sha256_of "$T/golden.pkg")" = "$(cat "$FX/product/product.sha256")" ] \
    || fail "the product differs from tests/fixtures/product/product.sha256"
  "$GOLDEN" expand "$T/golden.pkg" "$T/golden.x" || fail "stevedore expand of the golden product exited $?"
  cmp -s "$T/golden.x/Distribution" "$FX/product/Distribution" \
    || fail "the golden Distribution differs from tests/fixtures/product/Distribution: $(diff "$FX/product/Distribution" "$T/golden.x/Distribution" | head -8 | tr '\n' '|')"
else
  fail "stevedore-golden product of the fixture exited $?"
fi

if product_fixture "$SD" "$T/s" "$T/p.pkg"; then
  "$SD" expand "$T/p.pkg" "$T/p.x" || fail "stevedore expand of the product exited $?"
  cmp -s "$T/p.x/Distribution" "$FX/product/Distribution" \
    || fail "the Distribution differs from tests/fixtures/product/Distribution: $(diff "$FX/product/Distribution" "$T/p.x/Distribution" | head -8 | tr '\n' '|')"
  "$SD" toc "$T/p.pkg" > "$T/p.toc" || fail "stevedore toc of the product exited $?"
  members="$(sed -n 's/^ *<name>\(.*\)<\/name>$/\1/p' "$T/p.toc" | tr '\n' ' ')"
  want='Distribution Resources welcome.html license.txt conclusion.html product.pkg PackageInfo Scripts Payload Bom mavergreen-base.pkg PackageInfo Scripts Payload Bom '
  [ "$members" = "$want" ] || fail "the product holds '$members', not '$want'"
  styles="$(sed -n 's/^ *<encoding style="application\/\(.*\)"\/>$/\1/p' "$T/p.toc" | tr '\n' ' ')"
  want='x-gzip x-gzip x-gzip x-gzip x-gzip octet-stream octet-stream x-gzip x-gzip octet-stream octet-stream x-gzip '
  [ "$styles" = "$want" ] || fail "the product's encodings are '$styles', not '$want'"
  for k in mavergreen-base product; do
    "$SD" expand "$T/s/pkgs/$k.pkg" "$T/$k.x" || { fail "stevedore expand of $k.pkg exited $?"; continue; }
    same_tree "$T/$k.x" "$T/p.x/$k.pkg" "$k.pkg in the product"
  done
  for r in welcome.html license.txt conclusion.html; do
    cmp -s "$T/s/res/$r" "$T/p.x/Resources/$r" || fail "Resources/$r is not the --resources file"
  done
  [ "$(tail -c 1 "$T/p.x/Distribution")" = '>' ] || fail "the Distribution ends in a newline, which productbuild never writes"
else
  fail "stevedore product of the fixture exited $?"
fi

mkdir "$T/elsewhere"
(cd "$T/elsewhere" && umask 077 && TZ=Pacific/Kiritimati LC_ALL=C LANG=C product_fixture "$SD" "$T/s" "$T/p.a")
(umask 022 && TZ=America/New_York LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 product_fixture "$SD" "$T/s" "$T/p.b" 2>/dev/null)
cmp -s "$T/p.a" "$T/p.pkg" && cmp -s "$T/p.b" "$T/p.pkg" || fail "the product changes with TZ, umask, LC_ALL or the current directory"

s="$T/s"
pkgs="--package $s/pkgs/mavergreen-base.pkg --package $s/pkgs/product.pkg"
"$SD" product --distribution "$s/distribution.xml" $pkgs --resources "$s/res" --mtime "$((MT + 1))" --out "$T/mt.pkg" \
  && ! cmp -s "$T/mt.pkg" "$T/p.pkg" || fail "--mtime does not reach the product"

"$SD" product --distribution "$s/distribution.xml" $pkgs --mtime "$MT" --out "$T/nores.pkg" \
  && "$SD" expand "$T/nores.pkg" "$T/nores.x" && [ ! -e "$T/nores.x/Resources" ] \
  || fail "without --resources the product still holds Resources, or stevedore product failed"
grep -v '<license ' "$s/distribution.xml" > "$T/nolicense.xml"
mkdir "$T/res-missing"
cp "$s/res/welcome.html" "$s/res/conclusion.html" "$T/res-missing/"
"$SD" product --distribution "$s/distribution.xml" $pkgs --resources "$T/res-missing" --mtime "$MT" --out "$T/missing.pkg" \
  && "$SD" toc "$T/missing.pkg" > "$T/missing.toc" \
  && [ "$(sed -n 's/^ *<name>\(.*\)<\/name>$/\1/p' "$T/missing.toc" | sed -n '/^Resources$/,/^product.pkg$/p' | tr '\n' ' ')" = 'Resources welcome.html conclusion.html product.pkg ' ] \
  || fail "a referenced resource missing from --resources is not skipped as productbuild skips it"
sed 's#^    <welcome #    <background file="unreferenced.txt"/><readme file="license.txt"/><welcome #' "$T/nolicense.xml" > "$T/order.xml"
"$SD" product --distribution "$T/order.xml" $pkgs --resources "$s/res" --mtime "$MT" --out "$T/order.pkg" \
  && "$SD" toc "$T/order.pkg" > "$T/order.toc" \
  && [ "$(sed -n 's/^ *<name>\(.*\)<\/name>$/\1/p' "$T/order.toc" | sed -n '/^Resources$/,/^product.pkg$/p' | tr '\n' ' ')" = 'Resources unreferenced.txt welcome.html license.txt conclusion.html product.pkg ' ] \
  || fail "Resources are not in productbuild's background, welcome, readme, license, conclusion order"

mkdir "$T/ro"
echo keep > "$T/ro/out"
chmod 555 "$T/ro"
rc=0; "$SD" product --distribution "$s/distribution.xml" $pkgs --mtime "$MT" --out "$T/ro/out" 2>/dev/null || rc=$?
chmod 755 "$T/ro"
[ "$rc" -eq 1 ] && [ "$(cat "$T/ro/out")" = keep ] || fail "a failed write exited $rc and left $(cat "$T/ro/out") in an existing output"

refused() {
  want="$1"; shift
  rc=0; "$SD" product "$@" 2> "$T/err" || rc=$?
  [ "$rc" -eq 2 ] || fail "product $* exited $rc, not 2: $(cat "$T/err")"
  [ -z "$want" ] || grep -q -- "$want" "$T/err" || fail "product $* said: $(cat "$T/err")"
  [ ! -e "$T/bad.pkg" ] || { fail "a refused product $* still wrote an output"; rm -f "$T/bad.pkg"; }
}
dist() { sed "$1" "$s/distribution.xml" > "$T/$2.xml"; }
out="--mtime $MT --out $T/bad.pkg"
refused '' $pkgs $out
refused '' --distribution "$s/distribution.xml" $out
refused '' --distribution "$s/distribution.xml" $pkgs --out "$T/bad.pkg"
refused '' --distribution "$s/distribution.xml" $pkgs --mtime "$MT"
refused '' --distribution "$s/distribution.xml" $pkgs $out --bogus 1
refused '' --distribution "$s/distribution.xml" --distribution "$s/distribution.xml" $pkgs $out
refused '' --distribution "$s/distribution.xml" $pkgs --resources "$s/res" --resources "$s/res" $out
refused '' --distribution "$s/distribution.xml" $pkgs --mtime -1 --out "$T/bad.pkg"
refused "$T/nonexistent.xml" --distribution "$T/nonexistent.xml" $pkgs $out
refused "dev.mavergreen.stevedore-test.product" --distribution "$s/distribution.xml" --package "$s/pkgs/mavergreen-base.pkg" $out

mkdir "$T/extra"
"$SD" component --root "$s/base" --identifier dev.mavergreen.stevedore-test.extra --version 1 --install-location / \
  --mtime "$MT" --out "$T/extra/extra.pkg"
refused "dev.mavergreen.stevedore-test.extra" --distribution "$s/distribution.xml" $pkgs --package "$T/extra/extra.pkg" $out
cp "$s/pkgs/product.pkg" "$T/extra/product2.pkg"
refused "dev.mavergreen.stevedore-test.product" --distribution "$s/distribution.xml" $pkgs --package "$T/extra/product2.pkg" $out
mkdir "$T/extra/again"
cp "$T/extra/extra.pkg" "$T/extra/again/product.pkg"
refused "product.pkg" --distribution "$s/distribution.xml" $pkgs --package "$T/extra/again/product.pkg" $out
cp "$s/pkgs/product.pkg" "$T/extra/product.bin"
refused "product.bin" --distribution "$s/distribution.xml" --package "$s/pkgs/mavergreen-base.pkg" --package "$T/extra/product.bin" $out

dist 's#<pkg-ref id="dev.mavergreen.base"/></choice>#<pkg-ref id="dev.mavergreen.base"/><pkg-ref id="dev.example.stray"/></choice>#' stray
refused "dev.example.stray" --distribution "$T/stray.xml" $pkgs $out
dist 's#>product.pkg</pkg-ref>#>other.pkg</pkg-ref>#' othername
refused "other.pkg" --distribution "$T/othername.xml" $pkgs $out
dist '/version="0" onConclusion="none">product.pkg/d' noref
refused "dev.mavergreen.stevedore-test.product" --distribution "$T/noref.xml" $pkgs $out
dist 's#<line choice="dev.mavergreen.base"/>#<line choice="dev.example.nochoice"/>#' nochoice
refused "dev.example.nochoice" --distribution "$T/nochoice.xml" $pkgs $out
dist 's#<line choice="dev.mavergreen.stevedore-test.product"/>##' unreached
refused "dev.mavergreen.stevedore-test.product" --distribution "$T/unreached.xml" $pkgs $out
dist 's#<title>Stevedore Test</title>#<title>Stevedore <b/>Test</title>#' mixed
refused "mixed" --distribution "$T/mixed.xml" $pkgs $out
dist 's#<title>Stevedore Test</title>#<title><![CDATA[x]]></title>#' cdata
refused "" --distribution "$T/cdata.xml" $pkgs $out
dist 's#<title>Stevedore Test</title>#<title>Stevedore &nbsp; Test</title>#' entity
refused "" --distribution "$T/entity.xml" $pkgs $out
dist '$d' truncated
refused "" --distribution "$T/truncated.xml" $pkgs $out
dist 's#<installer-gui-script minSpecVersion="1">#<!DOCTYPE x><installer-gui-script minSpecVersion="1">#' doctype
refused "" --distribution "$T/doctype.xml" $pkgs $out
dist 's#installer-gui-script#installer-script#g' notgui
refused "installer-gui-script" --distribution "$T/notgui.xml" $pkgs $out
mkdir "$T/lproj" "$T/lproj/en.lproj"
cp "$s/res/license.txt" "$s/res/conclusion.html" "$T/lproj/"
cp "$s/res/welcome.html" "$T/lproj/en.lproj/"
refused "welcome.html" --distribution "$s/distribution.xml" $pkgs --resources "$T/lproj" $out
dist 's#<welcome file="welcome.html"#<welcome file="../welcome.html"#' upward
refused "../welcome.html" --distribution "$T/upward.xml" $pkgs --resources "$s/res" $out
refused "$T/nores" --distribution "$s/distribution.xml" $pkgs --resources "$T/nores" $out
echo 'not a xar' > "$T/garbage.pkg"
refused "" --distribution "$s/distribution.xml" --package "$s/pkgs/mavergreen-base.pkg" --package "$T/garbage.pkg" $out
mkdir "$T/noinfo"
"$SD" xar --mtime "$MT" --out "$T/noinfo/product.pkg" zlib Bom "$s/res/license.txt"
refused "PackageInfo" --distribution "$s/distribution.xml" --package "$s/pkgs/mavergreen-base.pkg" --package "$T/noinfo/product.pkg" $out

[ "$fails" -eq 0 ] || { echo "product-test: $fails failure(s)" >&2; exit 1; }
echo "product-test: ok"
