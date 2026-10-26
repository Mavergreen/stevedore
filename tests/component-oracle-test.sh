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
. "$FX/oracle/normalize.sh"
. "$FX/oracle/compare.sh"
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
fat_x86_64_arm64() {
  _h="$(od -An -tx1 -N32 "$1" 2>/dev/null | tr -d ' \n')"
  case "$_h" in cafebabe00000002*) ;; *) return 1 ;; esac
  case "$(printf %s "$_h" | cut -c17-24) $(printf %s "$_h" | cut -c57-64)" in
    "01000007 0100000c"|"0100000c 01000007") return 0 ;;
  esac
  return 1
}
universal=""
for f in /usr/local/mavergreen/python315/bin/python3.15 /usr/local/mavergreen/ninja/bin/ninja /usr/local/mavergreen/cmake/bin/cmake; do
  [ -f "$f" ] && fat_x86_64_arm64 "$f" && { universal="$f"; break; }
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
fat_x86_64_arm64 "$T/fat/bin/synthetic" || fail "the synthetic Mach-O is not universal x86_64 and arm64"
[ -n "$universal" ] || echo "note: no installed universal family binary; the fat fixture holds only the synthetic one"

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
  same_component "$name" "$T/$name.pb" "$T/$name.sd"
  if [ -d "$T/$name.pb/Scripts" ]; then
    for s in preinstall postinstall; do
      [ ! -f "$T/$name.sd/Scripts/$s" ] || grep -q "<$s file=\"./$s\" timeout=\"600\"/>" "$T/$name.sd/PackageInfo" \
        || fail "$name: the $s entry has no timeout=\"600\""
    done
  fi
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
