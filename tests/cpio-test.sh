#!/bin/sh
# platform: host-agnostic
set -eu
STEVEDORE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$STEVEDORE_ROOT/build/lib.sh"
B="$(stevedore_build_dir)"
SD="${STEVEDORE:-$B/stevedore}"
LIMITS="${STEVEDORE_CPIO_LIMITS:-$B/stevedore-cpio-limits}"
FX="$STEVEDORE_ROOT/tests/fixtures/trees"
. "$FX/basic.sh"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -c1-64
  else openssl dgst -sha256 < "$1" | awk '{ print $NF }'
  fi
}

[ -x "$SD" ] || { echo "FAIL: no stevedore binary at $SD -- build it with sh build/build.sh, or set STEVEDORE" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cpio-test.XXXXXX")"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT

MT=1700000000
mkdir "$T/tree"
basic_tree "$T/tree"
"$SD" payload --root "$T/tree" --mtime "$MT" --out "$T/payload" || fail "stevedore payload exited $?"
gzip -t < "$T/payload" || fail "gzip -t rejects the payload"
gzip -dc < "$T/payload" > "$T/raw"

expected_names='.
./B
./a
./a-b
./a/b
./a/c
./a/c/d
./a/hello.txt
./a/run.sh
./a/zero
./emp
./link
./sp ace
./sp ace/жук€.txt'
got_names="$(cpio -it < "$T/raw" 2>/dev/null)"
[ "$got_names" = "$expected_names" ] || fail "cpio -it lists $(echo "$got_names" | tr '\n' '|'), not the byte-ordered tree"

cpio -itv < "$T/raw" 2>/dev/null | awk '{ print $1, $2, $3, $4, $5 }' | sed 's/ root root / root wheel /' > "$T/listing"
cat > "$T/listing.expected" <<'EOT'
drwxr-xr-x 8 root wheel 0
-rw-r--r-- 1 root wheel 6
drwxr-xr-x 7 root wheel 0
-rw-r--r-- 1 root wheel 5
drwxr-xr-x 2 root wheel 0
drwxr-xr-x 3 root wheel 0
drwxr-xr-x 2 root wheel 0
-rw-r--r-- 1 root wheel 6
-rwxr-xr-x 1 root wheel 17
-rw-r--r-- 1 root wheel 0
drwx------ 2 root wheel 0
lrwxr-xr-x 1 root wheel 11
drwxr-xr-x 3 root wheel 0
-rw-r--r-- 1 root wheel 5
EOT
cmp -s "$T/listing" "$T/listing.expected" \
  || fail "cpio -itv modes, link counts, owners or sizes differ from the expected: $(tr '\n' '|' < "$T/listing")"

grep -aq "$(printf '%011o' "$MT")" "$T/raw" || fail "the --mtime value is not in the payload"
[ $(($(wc -c < "$T/raw") % 512)) -eq 0 ] || fail "the cpio stream is not a whole number of 512-byte blocks"

mkdir "$T/x"
(cd "$T/x" && umask 022 && cpio -id < "$T/raw" >/dev/null 2>&1) || fail "cpio -id could not extract the payload"
[ "$(readlink "$T/x/link")" = a/hello.txt ] || fail "symlink did not round-trip"
[ -d "$T/x/a/b" ] && [ -z "$(ls -A "$T/x/a/b")" ] || fail "empty directory did not round-trip"
[ -f "$T/x/a/zero" ] && [ ! -s "$T/x/a/zero" ] || fail "0-byte file did not round-trip"
[ -x "$T/x/a/run.sh" ] && [ ! -x "$T/x/a/hello.txt" ] || fail "executable bit did not round-trip"
[ "$(cat "$T/x/sp ace/жук€.txt")" = utf8 ] || fail "space/UTF-8 name did not round-trip"
cmp -s "$T/x/a/run.sh" "$T/tree/a/run.sh" && cmp -s "$T/x/a/hello.txt" "$T/tree/a/hello.txt" || fail "file contents did not round-trip"

[ "$(sha256_of "$T/payload")" = "$(cat "$FX/basic.payload.sha256")" ] \
  || fail "payload of the basic tree differs from tests/fixtures/trees/basic.payload.sha256"


mkdir "$T/tree77"
(umask 077 && basic_tree "$T/tree77")
"$SD" payload --root "$T/tree77" --mtime "$MT" --out "$T/payload77" || fail "stevedore payload of the umask 077 tree exited $?"
cmp -s "$T/payload77" "$T/payload" || fail "a symlink made under umask 077 changes the payload"
gzip -dc < "$T/payload77" | cpio -itv 2>/dev/null | grep -q '^lrwxr-xr-x ' || fail "a symlink made under umask 077 does not list as lrwxr-xr-x"

mkdir "$T/ro"
echo keep > "$T/ro/out"
chmod 555 "$T/ro"
rc=0; "$SD" payload --root "$T/tree" --mtime "$MT" --out "$T/ro/out" 2>/dev/null || rc=$?
chmod 755 "$T/ro"
[ "$rc" -eq 1 ] && [ "$(cat "$T/ro/out")" = keep ] || fail "a failed write exited $rc and left $(cat "$T/ro/out") in an existing output"

mkdir "$T/elsewhere"
(cd "$T/elsewhere" && umask 077 && TZ=Pacific/Kiritimati LC_ALL=C LANG=C "$SD" payload --root "$T/tree" --mtime "$MT" --out "$T/p.a")
(umask 022 && TZ=America/New_York LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 "$SD" payload --root "$T/tree" --mtime "$MT" --out "$T/p.b" 2>/dev/null)
cmp -s "$T/p.a" "$T/payload" && cmp -s "$T/p.b" "$T/payload" || fail "payload changes with TZ, umask, LC_ALL or the current directory"

if [ "$(uname -s)" = Darwin ] && command -v pkgbuild >/dev/null 2>&1; then
  pkgbuild --root "$T/tree" --identifier test.stevedore.basic --version 1 "$T/pb.pkg" >/dev/null 2>&1 \
    && pkgutil --expand "$T/pb.pkg" "$T/pb" \
    && gzip -dc < "$T/pb/Payload" | TZ=UTC cpio -itv 2>/dev/null | LC_ALL=C sort > "$T/pb.listing" \
    || fail "could not make a pkgbuild payload to compare with"
  "$SD" payload --root "$T/tree" --mtime 1672574400 --out "$T/payload.pb"
  gzip -dc < "$T/payload.pb" | TZ=UTC cpio -itv 2>/dev/null | LC_ALL=C sort | cmp -s - "$T/pb.listing" \
    || fail "cpio -itv of the payload differs from pkgbuild's for the same tree"
fi

mkdir "$T/hl" "$T/hl/d"
echo one > "$T/hl/a"
ln "$T/hl/a" "$T/hl/d/b"
rc=0; "$SD" payload --root "$T/hl" --mtime "$MT" --out "$T/hl.out" 2> "$T/hl.err" || rc=$?
[ "$rc" -eq 2 ] || fail "a tree with a hard link exited $rc, not 2"
[ "$(cat "$T/hl.err")" = "stevedore: hard link: ./a" ] || fail "hard link diagnostic was: $(cat "$T/hl.err")"
[ ! -e "$T/hl.out" ] || fail "a refused tree still wrote an output file"

mkdir "$T/ff"
mkfifo "$T/ff/pipe"
rc=0; "$SD" payload --root "$T/ff" --mtime "$MT" --out "$T/ff.out" 2> "$T/ff.err" || rc=$?
[ "$rc" -eq 2 ] && [ "$(cat "$T/ff.err")" = "stevedore: fifo: ./pipe" ] || fail "a fifo exited $rc with: $(cat "$T/ff.err")"

for bad in -1 abc 1x ""; do
  rc=0; "$SD" payload --root "$T/tree" --mtime "$bad" --out "$T/bad.out" 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || fail "--mtime '$bad' exited $rc, not 2"
done
rc=0; "$SD" payload --root "$T/tree" --out "$T/bad.out" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "payload without --mtime exited $rc, not 2"
rc=0; "$SD" payload --root "$T/nonexistent" --mtime "$MT" --out "$T/bad.out" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "a missing root succeeded"

if [ -x "$LIMITS" ]; then
  expect_limit() {
    rc=0; "$LIMITS" "$1" > "$T/lim.out" 2> "$T/lim.err" || rc=$?
    if [ "$2" = ok ]; then
      [ "$rc" -eq 0 ] || fail "limits $1 exited $rc, not 0: $(cat "$T/lim.err")"
    else
      [ "$rc" -eq 2 ] || fail "limits $1 exited $rc, not 2"
      grep -q "^stevedore: $2: " "$T/lim.err" || fail "limits $1 said: $(cat "$T/lim.err")"
    fi
  }
  expect_limit size 'file too large'
  expect_limit size-max 'payload too large'
  expect_limit name 'path too long'
  expect_limit name-max ok
  expect_limit payload 'payload too large'
  expect_limit mtime 'mtime out of range'
else
  fail "no limits probe at $LIMITS -- the build makes it beside stevedore"
fi

[ "$fails" -eq 0 ] || { echo "cpio-test: $fails failure(s)" >&2; exit 1; }
echo "cpio-test: ok"
