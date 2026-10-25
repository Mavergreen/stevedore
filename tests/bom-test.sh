#!/bin/sh
# platform: host-agnostic
set -eu
STEVEDORE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$STEVEDORE_ROOT/build/lib.sh"
B="$(stevedore_build_dir)"
SD="${STEVEDORE:-$B/stevedore}"
FX="$STEVEDORE_ROOT/tests/fixtures/trees"
. "$FX/basic.sh"
. "$FX/many.sh"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -c1-64
  else openssl dgst -sha256 < "$1" | awk '{ print $NF }'
  fi
}

[ -x "$SD" ] || { echo "FAIL: no stevedore binary at $SD -- build it with sh build/build.sh, or set STEVEDORE" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/bom-test.XXXXXX")"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT

MT=1700000000
FIXTURE_MT=1672574400
mkdir "$T/basic" "$T/many"
basic_tree "$T/basic"
many_tree "$T/many"

for name in basic many; do
  "$SD" bom --root "$T/$name" --mtime "$MT" --out "$T/$name.bom" || { fail "stevedore bom of the $name tree exited $?"; continue; }
  [ "$(head -c 8 "$T/$name.bom")" = BOMStore ] || fail "the $name Bom does not start with BOMStore"
  [ "$(sha256_of "$T/$name.bom")" = "$(cat "$FX/$name.bom.sha256")" ] \
    || fail "Bom of the $name tree differs from tests/fixtures/trees/$name.bom.sha256"
done

mkdir "$T/basic77"
(umask 077 && basic_tree "$T/basic77")
"$SD" bom --root "$T/basic77" --mtime "$MT" --out "$T/basic77.bom" || fail "stevedore bom of the umask 077 tree exited $?"
cmp -s "$T/basic77.bom" "$T/basic.bom" || fail "a symlink made under umask 077 changes the Bom"

mkdir "$T/elsewhere"
(cd "$T/elsewhere" && umask 077 && TZ=Pacific/Kiritimati LC_ALL=C LANG=C "$SD" bom --root "$T/basic" --mtime "$MT" --out "$T/b.a")
(umask 022 && TZ=America/New_York LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 "$SD" bom --root "$T/basic" --mtime "$MT" --out "$T/b.b" 2>/dev/null)
cmp -s "$T/b.a" "$T/basic.bom" && cmp -s "$T/b.b" "$T/basic.bom" || fail "Bom changes with TZ, umask, LC_ALL or the current directory"

"$SD" bom --root "$T/basic" --mtime "$((MT + 1))" --out "$T/b.mt" || fail "stevedore bom with another --mtime exited $?"
! cmp -s "$T/b.mt" "$T/basic.bom" || fail "--mtime does not reach the Bom"

if command -v lsbom >/dev/null 2>&1; then
  TZ=UTC lsbom -p MUGsTfc "$T/basic.bom" > "$T/basic.lsbom" || fail "lsbom rejects the basic Bom"
  cat > "$T/basic.lsbom.expected" <<'EOT'
drwxr-xr-x	root	wheel			.	
-rw-r--r--	root	wheel	6	Tue Nov 14 22:13:20 2023	./B	1128938001
drwxr-xr-x	root	wheel			./a	
drwxr-xr-x	root	wheel			./a/b	
drwxr-xr-x	root	wheel			./a/c	
drwxr-xr-x	root	wheel			./a/c/d	
-rw-r--r--	root	wheel	6	Tue Nov 14 22:13:20 2023	./a/hello.txt	3015617425
-rwxr-xr-x	root	wheel	17	Tue Nov 14 22:13:20 2023	./a/run.sh	2512906546
-rw-r--r--	root	wheel	0	Tue Nov 14 22:13:20 2023	./a/zero	4294967295
-rw-r--r--	root	wheel	5	Tue Nov 14 22:13:20 2023	./a-b	3039240015
drwx------	root	wheel			./emp	
lrwxr-xr-x	root	wheel	11	Tue Nov 14 22:13:20 2023	./link	1930106902
drwxr-xr-x	root	wheel			./sp ace	
-rw-r--r--	root	wheel	5	Tue Nov 14 22:13:20 2023	./sp ace/жук€.txt	3460833443
EOT
  sed 's/ *	/	/g' "$T/basic.lsbom" | cmp -s - "$T/basic.lsbom.expected" \
    || fail "lsbom -p MUGsTfc of the basic Bom is: $(tr '\n' '|' < "$T/basic.lsbom")"
  [ "$(TZ=UTC lsbom -p f "$T/many.bom" | wc -l | tr -d ' ')" -eq 1202 ] || fail "lsbom does not list all 1202 paths of the many tree"
fi

if [ "$(uname -s)" = Darwin ] && command -v pkgbuild >/dev/null 2>&1; then
  same_listing() {
    TZ=UTC lsbom "$@" "$T/$name.pb/Bom" > "$T/pb.out"
    TZ=UTC lsbom "$@" "$T/$name.fx.bom" > "$T/sd.out"
    cmp -s "$T/pb.out" "$T/sd.out" || fail "lsbom $* of the $name Bom differs from pkgbuild's: $(diff "$T/pb.out" "$T/sd.out" | head -5 | tr '\n' '|')"
  }
  for name in basic many; do
    pkgbuild --root "$T/$name" --identifier test.stevedore.bom --version 1 --install-location / "$T/$name.pkg" >/dev/null 2>&1 \
      && pkgutil --expand "$T/$name.pkg" "$T/$name.pb" \
      || { fail "could not make a pkgbuild Bom of the $name tree to compare with"; continue; }
    "$SD" bom --root "$T/$name" --mtime "$FIXTURE_MT" --out "$T/$name.fx.bom" || { fail "stevedore bom of the $name tree at the fixture mtime exited $?"; continue; }
    same_listing -p MUGsTfc
    same_listing
    same_listing -s
  done
fi

mkdir "$T/ro"
echo keep > "$T/ro/out"
chmod 555 "$T/ro"
rc=0; "$SD" bom --root "$T/basic" --mtime "$MT" --out "$T/ro/out" 2>/dev/null || rc=$?
chmod 755 "$T/ro"
[ "$rc" -eq 1 ] && [ "$(cat "$T/ro/out")" = keep ] || fail "a failed write exited $rc and left $(cat "$T/ro/out") in an existing output"

mkdir "$T/hl" "$T/hl/d"
echo one > "$T/hl/a"
ln "$T/hl/a" "$T/hl/d/b"
rc=0; "$SD" bom --root "$T/hl" --mtime "$MT" --out "$T/hl.out" 2> "$T/hl.err" || rc=$?
[ "$rc" -eq 2 ] && [ "$(cat "$T/hl.err")" = "stevedore: hard link: ./a" ] || fail "a hard link exited $rc with: $(cat "$T/hl.err")"
[ ! -e "$T/hl.out" ] || fail "a refused tree still wrote an output file"

for bad in -1 abc 1x "" 4294967296; do
  rc=0; "$SD" bom --root "$T/basic" --mtime "$bad" --out "$T/bad.out" 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || fail "--mtime '$bad' exited $rc, not 2"
done
rc=0; "$SD" bom --root "$T/basic" --out "$T/bad.out" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "bom without --mtime exited $rc, not 2"
rc=0; "$SD" bom --root "$T/basic" --mtime "$MT" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "bom without --out exited $rc, not 2"
rc=0; "$SD" bom --root "$T/nonexistent" --mtime "$MT" --out "$T/bad.out" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "a missing root succeeded"
[ ! -e "$T/bad.out" ] || fail "a refused bom still wrote an output file"

[ "$fails" -eq 0 ] || { echo "bom-test: $fails failure(s)" >&2; exit 1; }
echo "bom-test: ok"
