#!/bin/sh
# platform: host-agnostic
set -eu
STEVEDORE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$STEVEDORE_ROOT/build/lib.sh"
B="$(stevedore_build_dir)"
SD="${STEVEDORE:-$B/stevedore}"
MISMATCH="${STEVEDORE_PIN_MISMATCH:-$B/stevedore-pin-mismatch}"
FX="$STEVEDORE_ROOT/tests/fixtures/gz"
. "$FX/inputs.sh"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

[ -x "$SD" ] || { echo "FAIL: no stevedore binary at $SD -- build it with sh build/build.sh, or set STEVEDORE" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gz-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

gz_inputs "$FX" "$T"
for name in random-1mib toc-text; do
  [ "$(gz_sha256 "$T/$name")" = "$(cat "$FX/$name.sha256")" ] \
    || fail "the $name input generated from tests/fixtures/gz/seed is not the recorded one; this host's openssl or awk differs"
done

for name in empty one-byte random-1mib toc-text; do
  "$SD" gzip < "$T/$name" > "$T/$name.gz" || { fail "stevedore gzip $name exited $?"; continue; }
  cmp -s "$T/$name.gz" "$FX/$name.gz" || fail "gzip of $name differs from tests/fixtures/gz/$name.gz"
  gzip -t < "$T/$name.gz" || fail "gzip -t rejects stevedore's gzip of $name"
  gzip -dc < "$T/$name.gz" | cmp -s - "$T/$name" || fail "gzip of $name does not decompress to its input"
done

for name in empty one-byte toc-text; do
  "$SD" zlib < "$T/$name" > "$T/$name.zz" || { fail "stevedore zlib $name exited $?"; continue; }
  cmp -s "$T/$name.zz" "$FX/$name.zz" || fail "zlib of $name differs from tests/fixtures/gz/$name.zz"
done

in_size="$(wc -c < "$T/toc-text")"
gz_size="$(wc -c < "$T/toc-text.gz")"
[ $((gz_size * 4)) -lt "$in_size" ] \
  || fail "toc-text compresses to $gz_size of $in_size bytes, so it no longer exercises deflate's matching and Huffman coding"

mkdir "$T/elsewhere"
for name in one-byte random-1mib toc-text; do
  (cd "$T/elsewhere" && umask 077 && TZ=Pacific/Kiritimati LC_ALL=C LANG=C "$SD" gzip) < "$T/$name" > "$T/$name.a.gz"
  (umask 022 && TZ=America/New_York LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 "$SD" gzip) < "$T/$name" > "$T/$name.b.gz" 2>/dev/null
  cmp -s "$T/$name.a.gz" "$T/$name.b.gz" || fail "gzip of $name changes with TZ, umask, LC_ALL or the current directory"
  cmp -s "$T/$name.a.gz" "$T/$name.gz" || fail "gzip of $name under a changed environment differs from the default run"
done

if [ -x "$MISMATCH" ]; then
  rc=0; "$MISMATCH" gzip < "$T/one-byte" > "$T/mismatch.out" 2> "$T/mismatch.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a stevedore whose pin differs from the linked zlib still ran"
  [ ! -s "$T/mismatch.out" ] || fail "a stevedore whose pin differs from the linked zlib wrote output"
  grep -q 'zlib' "$T/mismatch.err" || fail "a stevedore whose pin differs from the linked zlib did not say why: $(cat "$T/mismatch.err")"
else
  fail "no pin-mismatch probe at $MISMATCH -- the build makes it beside stevedore"
fi

[ "$fails" -eq 0 ] || { echo "gz-test: $fails failure(s)" >&2; exit 1; }
echo "gz-test: ok"
