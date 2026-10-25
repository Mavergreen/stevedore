#!/bin/sh
# platform: macOS-only -- pkgbuild, pkgutil and Installer are the oracle stevedore component is checked against
#   usage: sh tests/component-oracle-test.sh
#          Builds each fixture tree with stevedore component and with shipyard's build_component_pkg.sh
#          (pkgbuild), and compares the expanded pkgs. With passwordless sudo it then installs each pkg
#          into a scratch install location under a throwaway identifier and compares the receipts and
#          the installed tree, then forgets the receipt and removes the files. Exits 77 without pkgbuild,
#          and after the expanded comparisons without sudo.
set -eu
STEVEDORE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$STEVEDORE_ROOT/build/lib.sh"
B="$(stevedore_build_dir)"
SD="${STEVEDORE:-$B/stevedore}"
FX="$STEVEDORE_ROOT/tests/fixtures"
SHIPYARD_SCRIPTS="${SHIPYARD_SCRIPTS:-/usr/local/mavergreen/shipyard/share/cmake/MavericksShipyard/scripts}"
. "$FX/trees/basic.sh"
. "$FX/trees/many.sh"
. "$FX/trees/bundles.sh"
. "$FX/trees/scripts.sh"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

[ "$(uname -s)" = Darwin ] && command -v pkgbuild >/dev/null 2>&1 || { echo "component-oracle-test: SKIP (no pkgbuild)"; exit 77; }
[ -f "$SHIPYARD_SCRIPTS/build_component_pkg.sh" ] || { echo "component-oracle-test: SKIP (no build_component_pkg.sh in $SHIPYARD_SCRIPTS)"; exit 77; }
[ -x "$SD" ] || { echo "FAIL: no stevedore binary at $SD -- build it with sh build/build.sh, or set STEVEDORE" >&2; exit 1; }
sudo=0
sudo -n true 2>/dev/null && sudo=1

T="$(mktemp -d "${TMPDIR:-/tmp}/component-oracle.XXXXXX")"
S="$(mktemp -d /private/tmp/stevedore-oracle.XXXXXX)"
ids=""
cleanup() {
  if [ "$sudo" -eq 1 ]; then
    for id in $ids; do sudo -n pkgutil --forget "$id" >/dev/null 2>&1 || :; done
    sudo -n rm -rf "$S"
  fi
  rm -rf "$S" 2>/dev/null || :
  chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"
}
trap cleanup EXIT

MT=1672574400
fat_macho() {
  {
    printf '\312\376\272\276\000\000\000\002'
    printf '\001\000\000\007\000\000\000\003\000\000\020\000\000\000\000\040\000\000\000\014'
    printf '\001\000\000\014\000\000\000\000\000\000\040\000\000\000\000\040\000\000\000\014'
    head -c 4048 /dev/zero
    printf '\317\372\355\376\007\000\000\001\003\000\000\000\002\000\000\000'
    head -c 4080 /dev/zero
    printf '\317\372\355\376\014\000\000\001\000\000\000\000\002\000\000\000'
    head -c 16 /dev/zero
  } > "$1"
}
universal=""
for f in /usr/local/mavergreen/python315/bin/python3.15 /usr/local/mavergreen/ninja/bin/ninja /usr/local/mavergreen/cmake/bin/cmake; do
  [ -f "$f" ] && lipo -info "$f" 2>/dev/null | grep -q 'x86_64 arm64' && { universal="$f"; break; }
done

mkdir "$T/basic" "$T/many" "$T/bundles" "$T/fat" "$T/scripts"
basic_tree "$T/basic"
many_tree "$T/many"
bundles_tree "$T/bundles" "$FX/plist/app.binary1.plist"
scripts_tree "$T/scripts"
basic_tree "$T/fat"
mkdir "$T/fat/bin"
fat_macho "$T/fat/bin/synthetic"
[ -z "$universal" ] || cp "$universal" "$T/fat/bin/universal"
chmod 755 "$T/fat/bin" "$T/fat/bin"/*
find "$T/fat" -exec env TZ=UTC touch -h -t 202301011200 {} +
lipo -info "$T/fat/bin/synthetic" 2>/dev/null | grep -q 'x86_64 arm64' || fail "the synthetic Mach-O is not universal x86_64 and arm64"
[ -n "$universal" ] || echo "note: no installed universal family binary; the fat fixture holds only the synthetic one"

normalize() {
  awk '
    function norm(line,   pre, rest, n, a, i, j, t, out) {
      if (match(line, /^ *<[A-Za-z-]+/) == 0) return line
      pre = substr(line, 1, RLENGTH); rest = substr(line, RLENGTH + 1); n = 0
      while (match(rest, /^ [A-Za-z][A-Za-z-]*="[^"]*"/)) {
        t = substr(rest, 2, RLENGTH - 1); rest = substr(rest, RLENGTH + 1)
        if (t ~ /^generator-version=/ || t == "timeout=\"600\"") continue
        a[++n] = t
      }
      for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t }
      out = pre
      for (i = 1; i <= n; i++) out = out " " a[i]
      return out rest
    }
    function flush(   i, j, t) {
      for (i = 2; i <= nb; i++) { t = b[i]; for (j = i - 1; j >= 1 && b[j] > t; j--) b[j + 1] = b[j]; b[j + 1] = t }
      for (i = 1; i <= nb; i++) print b[i]
      nb = 0; ind = ""
    }
    {
      l = norm($0)
      if (match(l, /^ *<bundle /)) {
        if (nb > 0 && substr(l, 1, RLENGTH) != ind) flush()
        ind = substr(l, 1, RLENGTH); b[++nb] = l; next
      }
      flush(); print l
    }
    END { flush() }' "$1"
}

expanded() {
  name="$1"; shift
  id="dev.mavergreen.stevedore-test.$$.$name"
  loc="$S/$name"
  "$SD" component --root "$T/$name" --identifier "$id" --version 1.0 --install-location "$loc" --mtime "$MT" "$@" --out "$T/$name.sd.pkg" \
    || { fail "stevedore component of the $name tree exited $?"; return 1; }
  sh "$SHIPYARD_SCRIPTS/build_component_pkg.sh" --root "$T/$name" --identifier "$id" --version 1.0 --install-location "$loc" \
    "$@" --out "$T/$name.pb.pkg" >/dev/null 2>"$T/$name.pb.err" \
    || { fail "build_component_pkg.sh of the $name tree failed: $(tr '\n' '|' < "$T/$name.pb.err")"; return 1; }
  for k in sd pb; do
    pkgutil --expand "$T/$name.$k.pkg" "$T/$name.$k" || { fail "pkgutil --expand rejects the $k $name pkg"; return 1; }
  done
  (cd "$T/$name.pb" && find . | LC_ALL=C sort) > "$T/pb.list"
  (cd "$T/$name.sd" && find . | LC_ALL=C sort) > "$T/sd.list"
  cmp -s "$T/pb.list" "$T/sd.list" || fail "$name: the expanded pkgs hold other names: $(diff "$T/pb.list" "$T/sd.list" | tr '\n' '|')"
  for o in "-p MUGsTfc" "" "-s"; do
    TZ=UTC lsbom $o "$T/$name.pb/Bom" > "$T/pb.out"
    TZ=UTC lsbom $o "$T/$name.sd/Bom" > "$T/sd.out"
    cmp -s "$T/pb.out" "$T/sd.out" || fail "$name: lsbom $o differs: $(diff "$T/pb.out" "$T/sd.out" | head -6 | tr '\n' '|')"
  done
  for k in sd pb; do gzip -dc < "$T/$name.$k/Payload" | TZ=UTC cpio -itv 2>/dev/null | LC_ALL=C sort > "$T/$k.out"; done
  cmp -s "$T/pb.out" "$T/sd.out" || fail "$name: the payload listings differ: $(diff "$T/pb.out" "$T/sd.out" | head -6 | tr '\n' '|')"
  if [ -d "$T/$name.pb/Scripts" ]; then
    for k in sd pb; do (cd "$T/$name.$k/Scripts" && find . -exec stat -f '%Sp %z %m %N%SY' {} + | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort) > "$T/$k.out"; done
    cmp -s "$T/pb.out" "$T/sd.out" || fail "$name: the expanded Scripts differ: $(diff "$T/pb.out" "$T/sd.out" | head -6 | tr '\n' '|')"
    for s in preinstall postinstall; do
      [ ! -f "$T/$name.sd/Scripts/$s" ] || grep -q "<$s file=\"./$s\" timeout=\"600\"/>" "$T/$name.sd/PackageInfo" \
        || fail "$name: the $s entry has no timeout=\"600\""
    done
  fi
  normalize "$T/$name.pb/PackageInfo" > "$T/pb.out"
  normalize "$T/$name.sd/PackageInfo" > "$T/sd.out"
  cmp -s "$T/pb.out" "$T/sd.out" || fail "$name: the PackageInfos differ beyond generator-version, timeout and order: $(diff "$T/pb.out" "$T/sd.out" | head -12 | tr '\n' '|')"
  grep -q "generator-version=\"stevedore-$("$SD" --version | sed 's/^stevedore //')\"" "$T/$name.sd/PackageInfo" \
    || fail "$name: generator-version is not stevedore-<version>"
  sh "$SHIPYARD_SCRIPTS/assert_pkg_installs_in_place.sh" "$T/$name.sd.pkg" >/dev/null 2>"$T/inplace.err" \
    || fail "$name: assert_pkg_installs_in_place.sh rejects the stevedore pkg: $(tr '\n' '|' < "$T/inplace.err")"
}

installed() {
  name="$1"; k="$2"
  id="dev.mavergreen.stevedore-test.$$.$name"
  loc="$S/$name"
  ids="$ids $id"
  sudo -n installer -pkg "$T/$name.$k.pkg" -target / >"$T/install.out" 2>&1 \
    || { fail "$name: installer rejects the $k pkg: $(tr '\n' '|' < "$T/install.out")"; return 1; }
  {
    echo "== pkg-info"; pkgutil --pkg-info "$id" | grep -v '^install-time:'
    echo "== files"; pkgutil --files "$id"
    echo "== tree"; (cd "$loc" && sudo -n find . -exec stat -f '%Sp %Su %Sg %z %m %N%SY' {} + | awk -v mt="$MT" '$5 != mt { $5 = "install-time" } { print }' | LC_ALL=C sort)
    echo "== contents"; (cd "$loc" && sudo -n find . -type f -exec cksum {} + | LC_ALL=C sort)
    echo "== scripts ran"; cat "$loc.scripts-ran" 2>/dev/null || :
    # platform: 10.9 pkgutil --file-info finds a file by its path under the install location, not its absolute path
    for f in synthetic universal; do
      [ -f "$loc/bin/$f" ] || continue
      echo "== file-info $f"; pkgutil --file-info "bin/$f" | grep -v '^install-time:'
    done
    echo "== receipt"; TZ=UTC lsbom -p MUGsTfc "/var/db/receipts/$id.bom"
  } > "$T/$name.$k.installed" 2>&1
  TZ=UTC lsbom --arch x86_64 "/var/db/receipts/$id.bom" > "$T/$name.$k.arch" 2>&1 || :
  sudo -n pkgutil --forget "$id" >/dev/null
  sudo -n rm -rf "$loc" "$loc.scripts-ran"
}

expanded basic --scripts "$T/scripts" || :
expanded many || :
expanded bundles || :
expanded fat || :

[ "$sudo" -eq 1 ] || {
  [ "$fails" -eq 0 ] || { echo "component-oracle-test: $fails failure(s)" >&2; exit 1; }
  echo "component-oracle-test: SKIP the install comparison (no passwordless sudo)"; exit 77
}

for name in basic bundles fat; do
  [ -f "$T/$name.sd.pkg" ] && [ -f "$T/$name.pb.pkg" ] || continue
  installed "$name" pb && installed "$name" sd || continue
  cmp -s "$T/$name.pb.installed" "$T/$name.sd.installed" \
    || fail "$name: the installs differ: $(diff "$T/$name.pb.installed" "$T/$name.sd.installed" | head -12 | tr '\n' '|')"
  grep -q . "$T/$name.pb.installed" || fail "$name: nothing was recorded for the install"
  cmp -s "$T/$name.pb.arch" "$T/$name.sd.arch" \
    || echo "note: $name: lsbom --arch x86_64 of the receipts differs (stevedore writes no BOM arch records): $(diff "$T/$name.pb.arch" "$T/$name.sd.arch" | tr '\n' '|')"
done
grep -q "^pkgid: dev.mavergreen.stevedore-test.$$.fat$" "$T/fat.sd.installed" || fail "fat: pkgutil --file-info does not know the installed Mach-O"
grep -q '^preinstall$' "$T/basic.sd.installed" && grep -q '^postinstall$' "$T/basic.sd.installed" \
  || fail "basic: the stevedore pkg's preinstall and postinstall did not both run"

[ "$fails" -eq 0 ] || { echo "component-oracle-test: $fails failure(s)" >&2; exit 1; }
echo "component-oracle-test: ok"
