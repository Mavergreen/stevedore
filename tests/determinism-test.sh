#!/bin/sh
# platform: host-agnostic
#   usage: sh tests/determinism-test.sh
#          Builds the fixture component pkgs (basic, with its scripts, and bundles) and the fixture
#          product, with its two components, twice: once under TZ=Pacific/Kiritimati, umask 077 and
#          LC_ALL=C, and once under TZ=America/New_York, umask 022 and a UTF-8 LC_ALL, each from its own
#          current directory and its own input trees, whose mtimes differ between the runs. Every pkg,
#          from stevedore-golden and from stevedore, must be the same bytes in both runs, and the golden
#          ones must match tests/fixtures/component/{basic,bundles}.sha256 and
#          tests/fixtures/product/product.sha256. With STEVEDORE_DETERMINISM_OUT=DIR it also copies the
#          pkgs into DIR beside a SHA256SUMS of them, which CI compares across hosts.
set -eu
STEVEDORE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$STEVEDORE_ROOT/build/lib.sh"
B="$(stevedore_build_dir)"
SD="${STEVEDORE:-$B/stevedore}"
GOLDEN="${STEVEDORE_GOLDEN:-$B/stevedore-golden}"
FX="$STEVEDORE_ROOT/tests/fixtures"
. "$FX/trees/basic.sh"
. "$FX/trees/bundles.sh"
. "$FX/trees/scripts.sh"
. "$FX/component/build.sh"
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
for g in component/basic.sha256 component/bundles.sha256 product/product.sha256; do
  [ -s "$FX/$g" ] || { echo "FAIL: no golden at tests/fixtures/$g -- write it with the generate.sh beside it" >&2; exit 1; }
done

utf8="$(locale -a 2>/dev/null | awk '{ n = tolower($0); gsub(/-/, "", n) } n == "en_us.utf8" || n == "c.utf8" { print; exit }')"
[ -n "$utf8" ] || { echo "FAIL: this host lists neither en_US.UTF-8 nor C.UTF-8 in locale -a, so LC_ALL cannot be varied" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/determinism-test.XXXXXX")"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT

mkdir "$T/shim" "$T/cwd-a" "$T/cwd-b"
cat > "$T/shim/touch" <<EOF
#!/bin/sh
n=\$#
for a in "\$@"; do
  [ "\$a" != 202301011200 ] || a=199901020304
  set -- "\$@" "\$a"
done
shift "\$n"
exec "$(command -v touch)" "\$@"
EOF
chmod 755 "$T/shim/touch"

PKGS="basic bundles product mavergreen-base product-component"
build_all() {
  for k in golden sd; do
    case "$k" in golden) bin="$GOLDEN" ;; *) bin="$SD" ;; esac
    mkdir "$1/$k" "$1/$k/p"
    component_fixtures "$1/$k"
    component_fixture "$bin" "$1/$k" basic "$1/$k/basic.pkg" || fail "$k component of the basic tree in $1 exited $?"
    component_fixture "$bin" "$1/$k" bundles "$1/$k/bundles.pkg" || fail "$k component of the bundles tree in $1 exited $?"
    product_inputs "$bin" "$1/$k/p" || fail "$k component of the product inputs in $1 exited $?"
    product_fixture "$bin" "$1/$k/p" "$1/$k/product.pkg" || fail "$k product in $1 exited $?"
    cp "$1/$k/p/pkgs/mavergreen-base.pkg" "$1/$k/mavergreen-base.pkg" || fail "$k: the product inputs in $1 hold no mavergreen-base.pkg to compare"
    cp "$1/$k/p/pkgs/product.pkg" "$1/$k/product-component.pkg" || fail "$k: the product inputs in $1 hold no product.pkg to compare"
  done
  [ "$fails" -eq 0 ]
}

mkdir "$T/a" "$T/b"
(cd "$T/cwd-a" && umask 077 && TZ=Pacific/Kiritimati LC_ALL=C LANG=C && export TZ LC_ALL LANG && build_all "$T/a") \
  || fail "the run under Pacific/Kiritimati, umask 077 and C failed"
(cd "$T/cwd-b" && umask 022 && TZ=America/New_York LC_ALL="$utf8" LANG="$utf8" PATH="$T/shim:$PATH" \
  && export TZ LC_ALL LANG PATH && build_all "$T/b") \
  || fail "the run under America/New_York, umask 022, $utf8 and other mtimes failed"

[ -n "$(find "$T/a/golden/basic/B" -newer "$T/b/golden/basic/B")" ] \
  && [ -n "$(find "$T/a/golden/p/res/license.txt" -newer "$T/b/golden/p/res/license.txt")" ] \
  || fail "the second run's input trees do not carry other mtimes, so the test varies less than it says"

for k in golden sd; do
  for n in $PKGS; do
    [ -f "$T/a/$k/$n.pkg" ] && [ -f "$T/b/$k/$n.pkg" ] || { fail "$k: $n.pkg was not written in both runs"; continue; }
    cmp -s "$T/a/$k/$n.pkg" "$T/b/$k/$n.pkg" \
      || fail "$k: $n.pkg changes with TZ, umask, LC_ALL, the current directory or the input trees' mtimes"
  done
done

for g in basic:component/basic.sha256 bundles:component/bundles.sha256 product:product/product.sha256; do
  n="${g%%:*}"; f="${g#*:}"
  [ -f "$T/a/golden/$n.pkg" ] || continue
  [ "$(sha256_of "$T/a/golden/$n.pkg")" = "$(cat "$FX/$f")" ] || fail "the golden $n.pkg differs from tests/fixtures/$f"
done

if [ -n "${STEVEDORE_DETERMINISM_OUT:-}" ]; then
  mkdir -p "$STEVEDORE_DETERMINISM_OUT"
  : > "$STEVEDORE_DETERMINISM_OUT/SHA256SUMS"
  for k in golden sd; do
    for n in $PKGS; do
      [ -f "$T/a/$k/$n.pkg" ] || continue
      cp "$T/a/$k/$n.pkg" "$STEVEDORE_DETERMINISM_OUT/$k-$n.pkg"
      printf '%s  %s\n' "$(sha256_of "$T/a/$k/$n.pkg")" "$k-$n.pkg" >> "$STEVEDORE_DETERMINISM_OUT/SHA256SUMS"
    done
  done
fi

[ "$fails" -eq 0 ] || { echo "determinism-test: $fails failure(s)" >&2; exit 1; }
echo "determinism-test: ok ($utf8 against C)"
