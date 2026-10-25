#!/bin/sh
# platform: macOS-only -- PlistBuddy and plutil on Mac OS X 10.9 are the oracle these fixtures record
#   usage: sh tests/fixtures/plist/generate.sh
#          For each NAME.plist here, writes NAME.binary1.plist (plutil -convert binary1), NAME.xml1
#          (plutil -convert xml1), NAME.get (for each line of NAME.keys, "rc=N" and what
#          `PlistBuddy -c 'Print :KEY'` printed, under TZ=UTC) and NAME.set.xml1 (NAME.sets applied
#          in order with PlistBuddy Set, or Add when the entry is missing, then plutil -convert xml1).
#          Run it on 10.9 only, and say so in the commit.
set -eu
FX="$(cd "$(dirname "$0")" && pwd)"
PB=/usr/libexec/PlistBuddy
[ "$(sw_vers -productVersion | cut -d. -f1-2)" = 10.9 ] || { echo "generate.sh: the oracle is 10.9's PlistBuddy and plutil" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/plist-generate.XXXXXX")"
trap 'rm -rf "$T"' EXIT
for src in "$FX"/*.plist; do
  case "$src" in *.binary1.plist) continue ;; esac
  name="$(basename "$src" .plist)"
  plutil -convert binary1 -o "$FX/$name.binary1.plist" "$src"
  plutil -convert xml1 -o "$FX/$name.xml1" "$src"
  : > "$FX/$name.get"
  while IFS= read -r k; do
    rc=0; TZ=UTC "$PB" -c "Print :$k" "$src" > "$T/out" 2>/dev/null || rc=$?
    [ "$rc" -eq 0 ] || : > "$T/out"
    { echo "rc=$rc"; cat "$T/out"; } >> "$FX/$name.get"
  done < "$FX/$name.keys"
  cp "$src" "$T/set.plist"
  while read -r k type value; do
    if "$PB" -c "Print :$k" "$T/set.plist" >/dev/null 2>&1; then
      "$PB" -c "Set :$k \"$value\"" "$T/set.plist"
    else
      "$PB" -c "Add :$k $type \"$value\"" "$T/set.plist"
    fi
  done < "$FX/$name.sets"
  plutil -convert xml1 -o "$FX/$name.set.xml1" "$T/set.plist"
done
