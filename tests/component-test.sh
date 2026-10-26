#!/bin/sh
# platform: host-agnostic
set -eu
STEVEDORE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$STEVEDORE_ROOT/build/lib.sh"
B="$(stevedore_build_dir)"
SD="${STEVEDORE:-$B/stevedore}"
GOLDEN="${STEVEDORE_GOLDEN:-$B/stevedore-golden}"
LIMITS="${STEVEDORE_COMPONENT_LIMITS:-$B/stevedore-component-limits}"
FX="$STEVEDORE_ROOT/tests/fixtures"
. "$FX/trees/basic.sh"
. "$FX/trees/bundles.sh"
. "$FX/trees/scripts.sh"
. "$FX/component/build.sh"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -c1-64
  else openssl dgst -sha256 < "$1" | awk '{ print $NF }'
  fi
}

[ -x "$SD" ] || { echo "FAIL: no stevedore binary at $SD -- build it with sh build/build.sh, or set STEVEDORE" >&2; exit 1; }
[ -x "$GOLDEN" ] || { echo "FAIL: no stevedore-golden binary at $GOLDEN -- the build makes it beside stevedore, or set STEVEDORE_GOLDEN" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/component-test.XXXXXX")"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT

MT=1672574400
component_fixtures "$T"
pkg_of() { component_fixture "$2" "$T" "$1" "$3"; }

same_tree() {
  (cd "$1" && find . | LC_ALL=C sort) > "$T/a.list"
  (cd "$2" && find . | LC_ALL=C sort) > "$T/b.list"
  cmp -s "$T/a.list" "$T/b.list" || { fail "$3: names differ: $(diff "$T/a.list" "$T/b.list" | head -6 | tr '\n' '|')"; return; }
  while IFS= read -r p; do
    [ "$(ls -ld "$1/$p" | cut -c1-10)" = "$(ls -ld "$2/$p" | cut -c1-10)" ] || fail "$3: $p has another mode"
    [ -f "$1/$p" ] && ! [ -h "$1/$p" ] || continue
    cmp -s "$1/$p" "$2/$p" || fail "$3: $p differs"
  done < "$T/a.list"
}

version="$("$SD" --version)" || fail "stevedore --version exited $?"
case "$version" in "stevedore "?*) ;; *) fail "stevedore --version printed '$version'" ;; esac
version="${version#stevedore }"

for name in basic bundles; do
  pkg_of "$name" "$GOLDEN" "$T/$name.golden.pkg" || { fail "stevedore-golden component of the $name tree exited $?"; continue; }
  [ "$(sha256_of "$T/$name.golden.pkg")" = "$(cat "$FX/component/$name.sha256")" ] \
    || fail "the $name pkg differs from tests/fixtures/component/$name.sha256"
  "$GOLDEN" expand "$T/$name.golden.pkg" "$T/$name.golden" || fail "stevedore expand of the golden $name pkg exited $?"
  cmp -s "$T/$name.golden/PackageInfo" "$FX/component/$name.PackageInfo" \
    || fail "the $name PackageInfo differs from tests/fixtures/component/$name.PackageInfo: $(diff "$FX/component/$name.PackageInfo" "$T/$name.golden/PackageInfo" | head -8 | tr '\n' '|')"
  pkg_of "$name" "$SD" "$T/$name.pkg" || { fail "stevedore component of the $name tree exited $?"; continue; }
  "$SD" expand "$T/$name.pkg" "$T/$name.x" || { fail "stevedore expand of the $name pkg exited $?"; continue; }
  sed "s/generator-version=\"stevedore-0-golden\"/generator-version=\"stevedore-$version\"/" "$FX/component/$name.PackageInfo" > "$T/$name.want"
  sed "" "$T/$name.x/PackageInfo" | cmp -s - "$T/$name.want" \
    || fail "the $name PackageInfo is not the fixture with generator-version stevedore-$version: $(sed "" "$T/$name.x/PackageInfo" | diff "$T/$name.want" - | head -8 | tr '\n' '|')"
  "$SD" bom --root "$T/$name" --mtime "$MT" --out "$T/$name.bom" && cmp -s "$T/$name.x/Bom" "$T/$name.bom" \
    || fail "the $name pkg's Bom is not what stevedore bom writes"
  "$SD" payload --root "$T/$name" --mtime "$MT" --out "$T/$name.payload" && cmp -s "$T/$name.x/Payload" "$T/$name.payload" \
    || fail "the $name pkg's Payload is not what stevedore payload writes"
  "$SD" toc "$T/$name.pkg" > "$T/$name.toc" || fail "stevedore toc of the $name pkg exited $?"
  members="$(sed -n 's/^ *<name>\(.*\)<\/name>$/\1/p' "$T/$name.toc" | tr '\n' ' ')"
  case "$name" in
    basic) want='Bom Payload Scripts PackageInfo ' ;;
    *) want='Bom Payload PackageInfo ' ;;
  esac
  [ "$members" = "$want" ] || fail "the $name pkg holds '$members', not '$want'"
  styles="$(sed -n 's/^ *<encoding style="\(.*\)"\/>$/\1/p' "$T/$name.toc" | tr '\n' ' ')"
  case "$name" in
    basic) want='application/x-gzip application/octet-stream application/octet-stream application/x-gzip ' ;;
    *) want='application/x-gzip application/octet-stream application/x-gzip ' ;;
  esac
  [ "$styles" = "$want" ] || fail "the $name pkg's encodings are '$styles', not '$want'"
done
[ -d "$T/basic.x/Scripts" ] && same_tree "$T/scripts" "$T/basic.x/Scripts" "the Scripts of the basic pkg"

mkdir "$T/elsewhere"
np="--identifier x --version 1 --install-location /Library/Np --mtime $MT"
"$SD" component --nopayload $np --scripts "$T/scripts" --out "$T/np.pkg" \
  && "$SD" toc "$T/np.pkg" > "$T/np.toc" && "$SD" expand "$T/np.pkg" "$T/np.x" || fail "stevedore component --nopayload with scripts exited $?"
members="$(sed -n 's/^ *<name>\(.*\)<\/name>$/\1/p' "$T/np.toc" | tr '\n' ' ')"
[ "$members" = 'Scripts PackageInfo ' ] || fail "the --nopayload pkg holds '$members', not 'Scripts PackageInfo '"
! grep -q '<payload' "$T/np.x/PackageInfo" || fail "the --nopayload PackageInfo has a payload element"
grep -q '<postinstall file="./postinstall" timeout="600"/>' "$T/np.x/PackageInfo" || fail "the --nopayload PackageInfo does not name the postinstall"
same_tree "$T/scripts" "$T/np.x/Scripts" "the Scripts of the --nopayload pkg"
"$SD" component --nopayload $np --out "$T/np0.pkg" && "$SD" toc "$T/np0.pkg" > "$T/np0.toc" || fail "stevedore component --nopayload without scripts exited $?"
members="$(sed -n 's/^ *<name>\(.*\)<\/name>$/\1/p' "$T/np0.toc" | tr '\n' ' ')"
[ "$members" = 'PackageInfo ' ] || fail "the scriptless --nopayload pkg holds '$members', not 'PackageInfo '"
"$SD" expand "$T/np0.pkg" "$T/np0.x" && ! grep -q '<payload' "$T/np0.x/PackageInfo" || fail "the scriptless --nopayload PackageInfo has a payload element"
(cd "$T/elsewhere" && umask 077 && TZ=Pacific/Kiritimati LC_ALL=C LANG=C "$SD" component --nopayload $np --scripts "$T/scripts" --out "$T/np.a")
(umask 022 && TZ=America/New_York LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 "$SD" component --nopayload $np --scripts "$T/scripts" --out "$T/np.b" 2>/dev/null)
cmp -s "$T/np.a" "$T/np.pkg" && cmp -s "$T/np.b" "$T/np.pkg" || fail "the --nopayload pkg changes with TZ, umask, LC_ALL or the current directory"

(cd "$T/elsewhere" && umask 077 && TZ=Pacific/Kiritimati LC_ALL=C LANG=C pkg_of bundles "$SD" "$T/p.a")
(umask 022 && TZ=America/New_York LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 pkg_of bundles "$SD" "$T/p.b" 2>/dev/null)
cmp -s "$T/p.a" "$T/bundles.pkg" && cmp -s "$T/p.b" "$T/bundles.pkg" || fail "the pkg changes with TZ, umask, LC_ALL or the current directory"

"$SD" component --root "$T/bundles" --identifier x --version 1 --install-location / --mtime "$((MT + 1))" --out "$T/mt.pkg" \
  && "$SD" component --root "$T/bundles" --identifier x --version 1 --install-location / --mtime "$MT" --out "$T/mt0.pkg" \
  && ! cmp -s "$T/mt.pkg" "$T/mt0.pkg" || fail "--mtime does not reach the pkg"

counts() {
  "$SD" component --root "$T/c/$1" --identifier x --version 1 --install-location / --mtime "$MT" --out "$T/c/$1.pkg" \
    && "$SD" expand "$T/c/$1.pkg" "$T/c/$1.x" || { fail "stevedore component of the $1 count tree exited $?"; return; }
  got="$(sed -n 's/^ *<payload \(.*\)\/>$/\1/p' "$T/c/$1.x/PackageInfo")"
  [ "$got" = "numberOfFiles=\"$2\" installKBytes=\"$3\"" ] || fail "the $1 tree counts $got, not $2 files and $3 KB as pkgbuild on 10.9 does"
}
mkdir "$T/c" "$T/c/empty" "$T/c/f1025" "$T/c/f0x100" "$T/c/d100" "$T/c/l600" "$T/c/f4097d14"
head -c 1025 /dev/zero > "$T/c/f1025/a"
i=0; while [ "$i" -lt 100 ]; do : > "$T/c/f0x100/f$i"; mkdir "$T/c/d100/d$i"; i=$((i + 1)); done
long="$(printf '%0600d' 0)"
for l in l m n; do ln -s "$long" "$T/c/l600/$l"; done
head -c 4097 /dev/zero > "$T/c/f4097d14/a"
mkdir "$T/c/f4097d14/s"
i=0; while [ "$i" -lt 14 ]; do : > "$T/c/f4097d14/s/f$i"; i=$((i + 1)); done
counts empty 1 0
counts f1025 2 2
counts f0x100 101 3
counts d100 101 53
counts l600 4 3
counts f4097d14 17 6

if [ -x "$LIMITS" ]; then
  got="$("$LIMITS")" || fail "stevedore-component-limits exited $?"
  [ "$got" = '    <payload numberOfFiles="18446744073709551615" installKBytes="18446744073709551615"/>' ] \
    || fail "the payload element for the largest counts is: $got"
else
  fail "no limits probe at $LIMITS -- the build makes it beside stevedore"
fi

mkdir "$T/ro"
echo keep > "$T/ro/out"
chmod 555 "$T/ro"
rc=0; pkg_of basic "$SD" "$T/ro/out" 2>/dev/null || rc=$?
chmod 755 "$T/ro"
[ "$rc" -eq 1 ] && [ "$(cat "$T/ro/out")" = keep ] || fail "a failed write exited $rc and left $(cat "$T/ro/out") in an existing output"

refused() {
  want="$1"; shift
  rc=0; "$SD" component "$@" 2> "$T/err" || rc=$?
  [ "$rc" -eq 2 ] || fail "component $* exited $rc, not 2"
  [ -z "$want" ] || grep -q -- "$want" "$T/err" || fail "component $* said: $(cat "$T/err")"
  [ ! -e "$T/bad.pkg" ] || { fail "a refused component $* still wrote an output"; rm -f "$T/bad.pkg"; }
}
ok="--identifier x --version 1 --install-location / --mtime $MT --out $T/bad.pkg"
refused '' --identifier x --version 1 --install-location / --mtime "$MT" --out "$T/bad.pkg"
refused '' --root "$T/basic" --version 1 --install-location / --mtime "$MT" --out "$T/bad.pkg"
refused '' --root "$T/basic" --identifier x --install-location / --mtime "$MT" --out "$T/bad.pkg"
refused '' --root "$T/basic" --identifier x --version 1 --mtime "$MT" --out "$T/bad.pkg"
refused '' --root "$T/basic" --identifier x --version 1 --install-location / --out "$T/bad.pkg"
refused '' --root "$T/basic" --identifier x --version 1 --install-location / --mtime "$MT"
refused '' --root "$T/basic" --identifier '' --version 1 --install-location / --mtime "$MT" --out "$T/bad.pkg"
refused '' --root "$T/basic" --identifier x --version 1 --install-location / --mtime "$MT" --out "$T/bad.pkg" --bogus 1
refused '' --root "$T/basic" --root "$T/basic" $ok
for bad in -1 abc 1x "" 4294967296; do
  refused '' --root "$T/basic" --identifier x --version 1 --install-location / --mtime "$bad" --out "$T/bad.pkg"
done
refused "$T/nonexistent" --root "$T/nonexistent" $ok
refused "not a directory" --root "$T/ro/out" $ok
refused "$T/noscripts" --root "$T/basic" --scripts "$T/noscripts" $ok
refused '' --nopayload --root "$T/basic" $ok
refused '' --nopayload --nopayload $ok
refused '' --nopayload --identifier x --version 1 --install-location / --out "$T/bad.pkg"
refused "$T/noscripts" --nopayload --scripts "$T/noscripts" $ok

mkdir "$T/hl" "$T/hl/d"
echo one > "$T/hl/a"
ln "$T/hl/a" "$T/hl/d/b"
refused "stevedore: hard link: ./a" --root "$T/hl" $ok
refused "stevedore: hard link: ./a" --root "$T/basic" --scripts "$T/hl" $ok

mkdir -p "$T/badplist/X.app/Contents"
echo garbage > "$T/badplist/X.app/Contents/Info.plist"
refused "./X.app/Contents/Info.plist" --root "$T/badplist" $ok
mkdir -p "$T/intid/X.app/Contents"
bundles_plist "$T/intid/X.app/Contents/Info.plist" CFBundleIdentifier '<integer>5</integer>'
refused "CFBundleIdentifier" --root "$T/intid" $ok
mkdir -p "$T/realver/X.app/Contents"
bundles_plist "$T/realver/X.app/Contents/Info.plist" CFBundleIdentifier '<string>x</string>' CFBundleVersion '<real>1.5</real>'
refused "CFBundleVersion" --root "$T/realver" $ok

[ "$fails" -eq 0 ] || { echo "component-test: $fails failure(s)" >&2; exit 1; }
echo "component-test: ok"
