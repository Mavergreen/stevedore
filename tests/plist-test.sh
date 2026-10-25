#!/bin/sh
# platform: host-agnostic
set -eu
STEVEDORE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$STEVEDORE_ROOT/build/lib.sh"
B="$(stevedore_build_dir)"
SD="${STEVEDORE:-$B/stevedore}"
FX="$STEVEDORE_ROOT/tests/fixtures/plist"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

[ -x "$SD" ] || { echo "FAIL: no stevedore binary at $SD -- build it with sh build/build.sh, or set STEVEDORE" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/plist-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

oct() { printf "\\$(printf %03o "$1")"; }
be64() { printf '\000\000\000\000\000\000\000'; oct "$1"; }
trailer() { printf '\000\000\000\000\000\000'; oct "$1"; oct "$2"; be64 "$3"; be64 "$4"; be64 "$5"; }

for name in app types components manifest many; do
  for form in plist binary1.plist; do
    f="$FX/$name.$form"
    "$SD" plist xml1 "$f" > "$T/out.xml1" || fail "stevedore plist xml1 $name.$form exited $?"
    cmp -s "$T/out.xml1" "$FX/$name.xml1" || fail "xml1 of $name.$form differs from plutil's: $(diff "$FX/$name.xml1" "$T/out.xml1" | head -6 | tr '\n' '|')"
    : > "$T/got"
    while IFS= read -r k; do
      rc=0; "$SD" plist get "$f" ":$k" > "$T/one" 2>/dev/null || rc=$?
      { echo "rc=$rc"; cat "$T/one"; } >> "$T/got"
    done < "$FX/$name.keys"
    cmp -s "$T/got" "$FX/$name.get" || fail "get of $name.$form differs from PlistBuddy's Print: $(diff "$FX/$name.get" "$T/got" | head -6 | tr '\n' '|')"
    cp "$f" "$T/set.plist"
    while read -r k type value; do
      "$SD" plist set "$T/set.plist" ":$k" "$type" "$value" || fail "set :$k $type $value on $name.$form exited $?"
    done < "$FX/$name.sets"
    cmp -s "$T/set.plist" "$FX/$name.set.xml1" || fail "set on $name.$form differs from PlistBuddy then plutil: $(diff "$FX/$name.set.xml1" "$T/set.plist" | head -6 | tr '\n' '|')"
  done
  [ "$(head -c 8 "$FX/$name.binary1.plist")" = bplist00 ] || fail "$name.binary1.plist is not binary1"
done

[ "$("$SD" plist get "$FX/app.binary1.plist" CFBundleIdentifier)" = org.mavergreen.example ] \
  || fail "a binary1 Info.plist does not yield its CFBundleIdentifier"
[ "$(LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8 "$SD" plist get "$FX/types.plist" :pi 2>/dev/null)" = 3.141590 ] \
  || fail "get of a real changes with the locale"
LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8 "$SD" plist xml1 "$FX/types.binary1.plist" 2>/dev/null | cmp -s - "$FX/types.xml1" \
  || fail "xml1 changes with the locale"

for c in "app.plist CFBundleDocumentTypes" "app.binary1.plist CFBundleDocumentTypes:0" "components.plist :" "types.plist :edict"; do
  set -- $c
  rc=0; "$SD" plist get "$FX/$1" "$2" > "$T/c.out" 2> "$T/c.err" || rc=$?
  [ "$rc" -eq 3 ] && [ ! -s "$T/c.out" ] && grep -q '^stevedore: ' "$T/c.err" \
    || fail "get of the container $2 in $1 exited $rc with: $(cat "$T/c.out" "$T/c.err")"
done

{ printf 'bplist00\321\001\002\121f\042\077\000\000\000\010\013\015'; trailer 1 1 3 0 18; } > "$T/float32.plist"
[ "$("$SD" plist get "$T/float32.plist" :f)" = 0.500000 ] || fail "a binary1 float32 does not read as 0.5"

{ printf 'bplist00\241\000\010'; trailer 1 1 1 0 10; } > "$T/cycle.plist"
{ printf 'bplist00\321\001\002\121f\042\077\000\000\000\010\013\310'; trailer 1 1 3 0 18; } > "$T/badoffset.plist"
{ printf 'bplist00\321\001\002\121f\042\077\000\000\000\010\013\015'; trailer 1 1 3 7 18; } > "$T/badtop.plist"
{ printf 'bplist00\321\001\002\121f\042\077\000\000\000\010\013\015'; trailer 1 1 200 0 18; } > "$T/badcount.plist"
{ printf 'bplist00\321\001\002\121f\200\000\010\013\015'; trailer 1 1 3 0 15; } > "$T/uid.plist"
{
  printf 'bplist00'
  i=0; while [ "$i" -lt 39 ]; do printf '\242'; oct $((i + 1)); oct $((i + 1)); i=$((i + 1)); done
  printf '\121a'
  i=0; while [ "$i" -lt 40 ]; do oct $((8 + 3 * i)); i=$((i + 1)); done
  trailer 1 1 40 0 127
} > "$T/bomb.plist"
: > "$T/empty.plist"
echo hello > "$T/garbage.plist"
head -c 100 "$FX/app.binary1.plist" > "$T/truncated.plist"
head -n 10 "$FX/app.plist" > "$T/unclosed.plist"
printf '<?xml version="1.0"?>\n<plist version="1.0">\n<dict><key>k</key><string>\377</string></dict>\n</plist>\n' > "$T/badutf8.plist"
printf '<plist version="1.0">\n<dict><key>k</key><bogus/></dict>\n</plist>\n' > "$T/element.plist"
printf '<plist version="1.0">\n<dict><key>k</key><integer>12x</integer></dict>\n</plist>\n' > "$T/badint.plist"
printf '<plist version="1.0">\n<dict><key>k</key><string>a</string></dict>\n</plist>\n<dict/>\n' > "$T/trailing.plist"
for bad in cycle badoffset badtop badcount uid bomb empty garbage truncated unclosed badutf8 element badint trailing nonexistent; do
  rc=0; "$SD" plist get "$T/$bad.plist" :k > "$T/m.out" 2> "$T/m.err" || rc=$?
  [ "$rc" -eq 2 ] && [ ! -s "$T/m.out" ] && grep -q '^stevedore: ' "$T/m.err" \
    || fail "get of the malformed $bad.plist exited $rc with: $(cat "$T/m.out" "$T/m.err" | head -3)"
  [ -e "$T/$bad.plist" ] || continue
  cp "$T/$bad.plist" "$T/m.before"
  rc=0; "$SD" plist set "$T/$bad.plist" :k string v 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] && cmp -s "$T/$bad.plist" "$T/m.before" || fail "set on the malformed $bad.plist exited $rc or changed it"
done

cp "$FX/app.plist" "$T/s.plist"
for c in "1 :Nope:x string v" "1 :CFBundleDocumentTypes:5 string v" "1 :CFBundleIdentifier:sub string v" \
         "2 :SUScheduledCheckInterval integer 12x" "2 :SUScheduledCheckInterval integer 99999999999999999999" \
         "2 :LSUIElement bool maybe" "2 :Ratio real 1e" "2 :Ratio real 0x1p3" "2 :When date 2023" "2 : string v" \
         "2 :LSUIElement string true" "2 :SUScheduledCheckInterval real 1.5" "2 :CFBundleDocumentTypes string v" \
         "2 :CFBundleDocumentTypes:0 string v"; do
  set -- $c
  rc=0; "$SD" plist set "$T/s.plist" "$2" "$3" "$4" 2> "$T/s.err" || rc=$?
  [ "$rc" -eq "$1" ] && grep -q '^stevedore: ' "$T/s.err" || fail "set $2 $3 $4 exited $rc, not $1: $(cat "$T/s.err")"
  cmp -s "$T/s.plist" "$FX/app.plist" || fail "a refused set $2 $3 $4 changed the file"
done

rc=0; "$SD" plist get "$FX/app.plist" :Nope > "$T/n.out" 2>/dev/null || rc=$?
[ "$rc" -eq 1 ] && [ ! -s "$T/n.out" ] || fail "get of a missing key exited $rc with: $(cat "$T/n.out")"
rc=0; "$SD" plist get "$FX/app.plist" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "plist get without a keypath exited $rc, not 2"
rc=0; "$SD" plist set "$FX/app.plist" :k string 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "plist set without a value exited $rc, not 2"

for c in "0 :CFBundleIdentifier" "0 :CFBundleDocumentTypes" "0 :CFBundleDocumentTypes:0" "0 :" "1 :Nope" "1 :CFBundleDocumentTypes:1"; do
  set -- $c
  for form in plist binary1.plist; do
    rc=0; "$SD" plist has "$FX/app.$form" "$2" > "$T/h.out" 2>&1 || rc=$?
    [ "$rc" -eq "$1" ] && [ ! -s "$T/h.out" ] || fail "has $2 in app.$form exited $rc, not $1: $(cat "$T/h.out")"
  done
done
rc=0; "$SD" plist has "$T/garbage.plist" :k 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "has on a malformed plist exited $rc, not 2"

cp "$FX/app.plist" "$T/mode.plist"
chmod 644 "$T/mode.plist"
(umask 077 && "$SD" plist set "$T/mode.plist" :CFBundleVersion string 242) || fail "set under umask 077 exited $?"
[ "$(ls -l "$T/mode.plist" | cut -c1-10)" = -rw-r--r-- ] || fail "set under umask 077 left $(ls -l "$T/mode.plist" | cut -c1-10), not the file's own -rw-r--r--"
chmod 600 "$T/mode.plist"
(umask 022 && "$SD" plist set "$T/mode.plist" :CFBundleVersion string 243) || fail "set under umask 022 exited $?"
[ "$(ls -l "$T/mode.plist" | cut -c1-10)" = -rw------- ] || fail "set under umask 022 left $(ls -l "$T/mode.plist" | cut -c1-10), not the file's own -rw-------"

cp "$FX/app.plist" "$T/target.plist"
ln -s target.plist "$T/link.plist"
rc=0; "$SD" plist set "$T/link.plist" :CFBundleVersion string 242 2> "$T/l.err" || rc=$?
[ "$rc" -eq 2 ] && grep -q '^stevedore: ' "$T/l.err" || fail "set through a symlink exited $rc, not 2: $(cat "$T/l.err")"
[ -h "$T/link.plist" ] && cmp -s "$T/target.plist" "$FX/app.plist" || fail "a refused set through a symlink changed the link or its target"

[ "$fails" -eq 0 ] || { echo "plist-test: $fails failure(s)" >&2; exit 1; }
echo "plist-test: ok"
