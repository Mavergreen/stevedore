#!/bin/sh
# platform: host-agnostic
set -eu
STEVEDORE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$STEVEDORE_ROOT/build/lib.sh"
B="$(stevedore_build_dir)"
SD="${STEVEDORE:-$B/stevedore}"
FX="$STEVEDORE_ROOT/tests/fixtures/xar"
. "$FX/inputs.sh"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -c1-64
  else openssl dgst -sha256 < "$1" | awk '{ print $NF }'
  fi
}

[ -x "$SD" ] || { echo "FAIL: no stevedore binary at $SD -- build it with sh build/build.sh, or set STEVEDORE" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/xar-test.XXXXXX")"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT

sha1_is() {
  got="$("$SD" sha1 < "$1")" || { fail "stevedore sha1 of $2 exited $?"; return; }
  [ "$got" = "$3" ] || fail "sha1 of $2 is $got, not $3"
}
printf abc > "$T/abc"
sha1_is "$T/abc" '"abc"' a9993e364706816aba3e25717850c26c9cd0d89d
printf abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq > "$T/448"
sha1_is "$T/448" 'the 448-bit message' 84983e441c3bd26ebaae4aa1f95129e5e54670f1
: > "$T/nothing"
sha1_is "$T/nothing" 'the empty message' da39a3ee5e6b4b0d3255bfef95601890afd80709
head -c 1000000 /dev/zero | tr '\000' a > "$T/million"
sha1_is "$T/million" 'one million a' 34aa973cd4c4daa4f61eeb2bdbad27316534016f
if command -v openssl >/dev/null 2>&1; then
  for n in 55 56 63 64 65 119 120 128 1048577; do
    head -c "$n" /dev/urandom > "$T/random"
    sha1_is "$T/random" "$n random bytes" "$(openssl dgst -sha1 < "$T/random" | awk '{ print $NF }')"
  done
fi

MT=1700000000
xar_inputs "$T" "$SD" || fail "could not make the archive inputs"
cp -R "$T/in" "$T/want"
rm "$T/want/base.pkg/Scripts"
cp -R "$T/scripts" "$T/want/base.pkg/Scripts"
xar_product() { (cd "$T/in" && xar_write "$SD" "$1" "$2"); }
xar_product "$MT" "$T/product.xar" || fail "stevedore xar of the product inputs exited $?"
[ "$(sha256_of "$T/product.xar")" = "$(cat "$FX/product.sha256")" ] \
  || fail "the product archive differs from tests/fixtures/xar/product.sha256"
[ "$(head -c 4 "$T/product.xar")" = 'xar!' ] || fail "the archive does not start with xar!"
hdr="$(od -An -tx1 -N28 "$T/product.xar" | tr -d ' \n')"
case "$hdr" in
  78617221001c000100000000????????00000000????????00000001) ;;
  *) fail "the header is not 28 bytes, version 1, sha1: $hdr" ;;
esac

"$SD" toc "$T/product.xar" > "$T/product.toc" || fail "stevedore toc exited $?"
cmp -s "$T/product.toc" "$FX/product.toc" \
  || fail "the TOC differs from tests/fixtures/xar/product.toc: $(diff "$FX/product.toc" "$T/product.toc" | head -6 | tr '\n' '|')"

"$SD" expand "$T/product.xar" "$T/ex" || fail "stevedore expand of our own archive exited $?"
same_tree() {
  (cd "$1" && find . | LC_ALL=C sort) > "$T/a.list"
  (cd "$2" && find . | LC_ALL=C sort) > "$T/b.list"
  cmp -s "$T/a.list" "$T/b.list" || { fail "$3: names differ: $(diff "$T/a.list" "$T/b.list" | head -6 | tr '\n' '|')"; return; }
  while IFS= read -r p; do
    [ "$(ls -ld "$1/$p" | cut -c1-10)" = "$(ls -ld "$2/$p" | cut -c1-10)" ] \
      || fail "$3: $p is $(ls -ld "$1/$p" | cut -c1-10) in one and $(ls -ld "$2/$p" | cut -c1-10) in the other"
    [ -f "$1/$p" ] || continue
    cmp -s "$1/$p" "$2/$p" || fail "$3: $p differs"
  done < "$T/a.list"
}
same_tree "$T/want" "$T/ex" "stevedore expand of our archive"

mkdir "$T/elsewhere"
(cd "$T/elsewhere" && umask 077 && TZ=Pacific/Kiritimati LC_ALL=C LANG=C xar_product "$MT" "$T/p.a")
(umask 022 && TZ=America/New_York LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 xar_product "$MT" "$T/p.b" 2>/dev/null)
cmp -s "$T/p.a" "$T/product.xar" && cmp -s "$T/p.b" "$T/product.xar" || fail "the archive changes with TZ, umask, LC_ALL or the current directory"
xar_product "$((MT + 1))" "$T/p.mt" || fail "stevedore xar with another --mtime exited $?"
! cmp -s "$T/p.mt" "$T/product.xar" || fail "--mtime does not reach the archive"

heap="$(( 28 + $(od -An -tu1 -j8 -N8 "$T/product.xar" | tr "\n" " " | awk '{ n = 0; for (i = 1; i <= NF; i++) n = n * 256 + $i; print n }') ))"
flip() { cp "$1" "$2"; b="$(od -An -tu1 -j"$3" -N1 "$2" | tr -d ' ')"; printf "\\$(printf %03o $(( (b + 1) % 256 )))" | dd of="$2" bs=1 seek="$3" conv=notrunc 2>/dev/null; }
refused() {
  rc=0; "$SD" expand "$1" "$T/out.$2" 2> "$T/err" || rc=$?
  [ "$rc" -eq 2 ] && [ "$(cat "$T/err")" = "$3" ] || fail "$2: expand exited $rc with: $(cat "$T/err")"
  [ ! -e "$T/out.$2" ] || fail "$2: expand wrote $T/out.$2 anyway"
  ! ls -a "$T" | grep -q "\.stevedore-" || fail "$2: expand left a temporary directory: $(ls -a "$T" | grep "\.stevedore-")"
}
payload_at="$(sed -n '/<name>Payload</,/<\/data>/s:.*<offset>\(.*\)</offset>.*:\1:p' "$FX/product.toc" | head -1)"
flip "$T/product.xar" "$T/flip-payload.xar" "$((heap + payload_at))"
refused "$T/flip-payload.xar" flip-payload "stevedore: checksum mismatch: base.pkg/Payload"
flip "$T/product.xar" "$T/flip-heap-end.xar" "$(( $(wc -c < "$T/product.xar") - 1 ))"
refused "$T/flip-heap-end.xar" flip-heap-end "stevedore: checksum mismatch: Distribution"
flip "$T/product.xar" "$T/flip-tocsum.xar" "$heap"
refused "$T/flip-tocsum.xar" flip-tocsum "stevedore: checksum mismatch: TOC"
flip "$T/product.xar" "$T/flip-toc.xar" 40
refused "$T/flip-toc.xar" flip-toc "stevedore: checksum mismatch: TOC"
rc=0; "$SD" toc "$T/flip-payload.xar" > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "toc of an archive with a flipped heap byte exited $rc, not 2"
head -c 100 "$T/product.xar" > "$T/short.xar"
rc=0; "$SD" expand "$T/short.xar" "$T/out.short" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$T/out.short" ] || fail "a truncated archive exited $rc"

oct() { printf "\\$(printf %03o "$1")"; }
be32() { oct $(( ($1 >> 24) & 255 )); oct $(( ($1 >> 16) & 255 )); oct $(( ($1 >> 8) & 255 )); oct $(( $1 & 255 )); }
hex2bin() { h="$1"; while [ -n "$h" ]; do oct "0x${h%"${h#??}"}"; h="${h#??}"; done; }
craft_raw() {
  "$SD" zlib < "$1" > "$T/craft.zz"
  { printf 'xar!\000\034\000\001'; be32 0; be32 "$(wc -c < "$T/craft.zz")"; be32 0; be32 "$(wc -c < "$1")"; be32 1
    cat "$T/craft.zz"; hex2bin "$("$SD" sha1 < "$T/craft.zz")"; cat "$2"; } > "$3"
}
craft() {
  data="${3:-$T/craft.data}"
  [ -n "${3:-}" ] || printf 'evil\n' > "$data"
  sum="$("$SD" sha1 < "$data")"
  len="$(wc -c < "$data" | tr -d ' ')"
  cat > "$T/craft.toc" <<EOT
<?xml version="1.0" encoding="UTF-8"?>
<xar>
 <toc>
  <checksum style="sha1"><size>20</size><offset>0</offset></checksum>
  $1
 </toc>
</xar>
EOT
  sed "s|@DATA@|<data><archived-checksum style=\"sha1\">$sum</archived-checksum><extracted-checksum style=\"sha1\">${6:-$sum}</extracted-checksum><encoding style=\"application/${4:-octet-stream}\"/><size>${5:-$len}</size><offset>20</offset><length>$len</length></data>|g" "$T/craft.toc" > "$T/craft.toc2"
  craft_raw "$T/craft.toc2" "$data" "$2"
}
craft '<file id="1"><name>ok</name><type>file</type>@DATA@</file>' "$T/ok.xar"
"$SD" expand "$T/ok.xar" "$T/out.ok" && [ "$(cat "$T/out.ok/ok")" = evil ] || fail "a crafted archive does not expand: the crafting itself is broken"
craft '<file id="1"><name>..</name><type>directory</type><file id="2"><name>x</name><type>file</type>@DATA@</file></file>' "$T/dotdot.xar"
refused "$T/dotdot.xar" dotdot "stevedore: unsafe name in archive: .."
craft '<file id="1"><name>/tmp/x</name><type>file</type>@DATA@</file>' "$T/abs.xar"
refused "$T/abs.xar" abs "stevedore: unsafe name in archive: /tmp/x"
craft '<file id="1"><name>a/../../x</name><type>file</type>@DATA@</file>' "$T/slash.xar"
refused "$T/slash.xar" slash "stevedore: unsafe name in archive: a/../../x"
craft '<file id="1"><name>link</name><type>symlink</type><link type="file">/etc/passwd</link></file>' "$T/symlink.xar"
refused "$T/symlink.xar" symlink "stevedore: symlink in archive: link"
craft '<file id="1"><name>x</name><type>file</type>@DATA@</file><file id="2"><name>x</name><type>file</type>@DATA@</file>' "$T/dup.xar"
rc=0; "$SD" expand "$T/dup.xar" "$T/out.dup" 2> "$T/err" || rc=$?
[ "$rc" -eq 2 ] && [ "$(cat "$T/err")" = "stevedore: duplicate name in archive: x" ] || fail "a duplicate name exited $rc with: $(cat "$T/err")"
[ ! -e "$T/out.dup" ] || fail "a duplicate name still left $T/out.dup"

printf 'evil\n' > "$T/craft.data"
craft '<file id="1"><name>good</name><type>file</type>@DATA@</file><file id="2"><name>bad</name><type>file</type>@DATA@</file>' \
  "$T/badsum.xar" "" octet-stream "" 0123456789abcdef0123456789abcdef01234567
sed "s|0123456789abcdef0123456789abcdef01234567|$sum|" "$T/craft.toc2" > "$T/badsum.toc"
craft_raw "$T/badsum.toc" "$T/craft.data" "$T/badsum.xar"
refused "$T/badsum.xar" badsum "stevedore: checksum mismatch: bad"
craft '<file id="1"><name>short</name><type>file</type>@DATA@</file>' "$T/short-size.xar" "" octet-stream 4
refused "$T/short-size.xar" short-size "stevedore: data larger than its declared size: short"
craft '<file id="1"><name>long</name><type>file</type>@DATA@</file>' "$T/long-size.xar" "" octet-stream 6
refused "$T/long-size.xar" long-size "stevedore: data smaller than its declared size: long"

head -c 10485760 /dev/zero | "$SD" zlib > "$T/bomb.zz"
craft '<file id="1"><name>bomb</name><type>file</type>@DATA@</file>' "$T/bomb.xar" "$T/bomb.zz" x-gzip 5
refused "$T/bomb.xar" bomb "stevedore: data larger than its declared size: bomb"
head -c 83886080 /dev/zero | "$SD" gzip > "$T/scripts-bomb.gz"
"$SD" xar --mtime "$MT" --out "$T/scripts-bomb.xar" none Scripts "$T/scripts-bomb.gz" || fail "could not write an archive holding a gzip bomb Scripts"
refused "$T/scripts-bomb.xar" scripts-bomb "stevedore: expands past 64 MiB: Scripts"
head -c 104857600 /dev/zero | "$SD" zlib > "$T/scripts-zbomb.zz"
craft '<file id="1"><name>Scripts</name><type>file</type>@DATA@</file>' "$T/scripts-zbomb.xar" "$T/scripts-zbomb.zz" x-gzip 107374182400
refused "$T/scripts-zbomb.xar" scripts-zbomb "stevedore: expands past 64 MiB: Scripts"

craft '<file id="1"><name>x</name><type>file</type><data><offset>20</offset>@DATA@</data></file>' "$T/dup-offset.xar"
sed 's|<data><offset>20</offset><data>|<data><offset>20</offset>|; s|</data></data>|</data>|' "$T/craft.toc2" > "$T/dup-offset.toc"
craft_raw "$T/dup-offset.toc" "$T/craft.data" "$T/dup-offset.xar"
refused "$T/dup-offset.xar" dup-offset "stevedore: malformed xar TOC: $T/dup-offset.xar"
craft '<file id="1"><name>x</name><type>file</type>@DATA@@DATA@</file>' "$T/dup-data.xar"
refused "$T/dup-data.xar" dup-data "stevedore: malformed xar TOC: $T/dup-data.xar"
craft '<file id="1"><name>x</name><type>file</type><type>file</type>@DATA@</file>' "$T/dup-type.xar"
refused "$T/dup-type.xar" dup-type "stevedore: malformed xar TOC: $T/dup-type.xar"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<xar>\n <toc>&#123' > "$T/numref.toc"
craft_raw "$T/numref.toc" "$T/craft.data" "$T/numref.xar"
refused "$T/numref.xar" numref "stevedore: malformed xar TOC: $T/numref.xar"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<xar>\n <toc>&#x7b' > "$T/hexref.toc"
craft_raw "$T/hexref.toc" "$T/craft.data" "$T/hexref.xar"
refused "$T/hexref.xar" hexref "stevedore: malformed xar TOC: $T/hexref.xar"

mkdir "$T/zb"
set --
head -c 262144 /dev/urandom > "$T/zb/random"
od -An -tx1 -N 120000 "$T/zb/random" > "$T/zb/text"
for n in 65535 65536 65537 131071 131072 131073 196608 262144; do
  head -c "$n" "$T/zb/random" > "$T/zb/r$n"
  set -- "$@" zlib "r$n" "r$n"
done
n=160000
while [ "$n" -le 200000 ]; do
  head -c "$n" "$T/zb/text" > "$T/zb/t$n"
  set -- "$@" zlib "t$n" "t$n"
  n=$((n + 997))
done
(cd "$T/zb" && "$SD" xar --mtime "$MT" --out "$T/zb.xar" "$@") || fail "stevedore xar of the 64 KiB boundary entries exited $?"
set --
"$SD" expand "$T/zb.xar" "$T/zb.out" || fail "stevedore expand of entries around 64 KiB exited $?"
for f in "$T/zb.out"/*; do cmp -s "$f" "$T/zb/${f##*/}" || fail "${f##*/} does not expand to its input"; done

odc() { printf '070707000000000001%06o00000000000000000100000000000000000%06o%011o%s\000' "$1" $(( ${#2} + 1 )) "$(printf %s "$3" | wc -c)" "$2"; printf %s "$3"; }
crafted_scripts() {
  { odc 040755 . ''; odc 0100644 first 'first'; odc "$1" "$2" "$3"; odc 0 'TRAILER!!!' ''; } > "$T/bad.cpio"
  "$SD" gzip < "$T/bad.cpio" > "$T/bad.cpio.gz"
  rm -f "$T/bad-scripts.xar"
  "$SD" xar --mtime "$MT" --out "$T/bad-scripts.xar" none Scripts "$T/bad.cpio.gz" || fail "could not write an archive holding a crafted Scripts"
}
bad_scripts() {
  crafted_scripts "$@"
  rc=0; "$SD" expand "$T/bad-scripts.xar" "$T/out.$4" 2> "$T/err" || rc=$?
  [ "$rc" -eq 2 ] && [ "$(cat "$T/err")" = "$5" ] || fail "$4: expand exited $rc with: $(cat "$T/err")"
  [ ! -e "$T/out.$4" ] || fail "$4: a refused Scripts left $T/out.$4"
}
crafted_scripts 0100644 ok evil
"$SD" expand "$T/bad-scripts.xar" "$T/out.good-scripts" || fail "stevedore expand of a crafted Scripts archive exited $?"
[ "$(cat "$T/out.good-scripts/Scripts/ok" 2>/dev/null)" = evil ] || fail "a crafted Scripts archive does not expand: the crafting itself is broken"
bad_scripts 0100644 ../evil evil scripts-dotdot "stevedore: unsafe name in cpio archive: ../evil"
bad_scripts 0100644 /tmp/evil evil scripts-abs "stevedore: unsafe name in cpio archive: /tmp/evil"
bad_scripts 0120755 link /etc scripts-symlink "stevedore: symlink in cpio archive: link"
[ ! -e "$T/evil" ] || fail "a Scripts archive wrote outside the expanded directory"
printf 'not gzip\n' > "$T/plain"
"$SD" xar --mtime "$MT" --out "$T/plain-scripts.xar" none x.pkg/Scripts "$T/plain" || fail "could not write an archive with a plain Scripts"
rc=0; "$SD" expand "$T/plain-scripts.xar" "$T/out.plain" 2> "$T/err" || rc=$?
[ "$rc" -eq 2 ] && [ "$(cat "$T/err")" = "stevedore: not a gzipped cpio archive: x.pkg/Scripts" ] || fail "a plain Scripts exited $rc with: $(cat "$T/err")"
[ ! -e "$T/out.plain" ] || fail "a refused plain Scripts left $T/out.plain"

mkdir "$T/exists"
rc=0; "$SD" expand "$T/product.xar" "$T/exists" 2>/dev/null || rc=$?
[ "$rc" -eq 1 ] && [ -z "$(ls "$T/exists")" ] || fail "expand into an existing directory exited $rc"

bad_writer() {
  rc=0; (cd "$T/in" && "$SD" xar --mtime "$MT" --out "$T/bad.xar" "$@") 2> "$T/err" || rc=$?
  [ "$rc" -eq 2 ] && [ ! -e "$T/bad.xar" ] || fail "xar $* exited $rc and wrote $(ls "$T/bad.xar" 2>/dev/null)"
}
bad_writer none Distribution Distribution none Distribution Distribution
bad_writer none base.pkg Distribution none base.pkg/Bom Distribution
bad_writer none base.pkg/Bom Distribution none base.pkg Distribution
bad_writer none ../x Distribution
bad_writer none /x Distribution
bad_writer none a//b Distribution
bad_writer none a/./b Distribution
bad_writer none a/ Distribution
for bad in "a\001b" "tab\there" "del\177" "bad\377" "over\300\257long" "sur\355\240\200rogate" "cut\342\202"; do
  bad_writer none "$(printf "$bad")" Distribution
  [ "$(cat "$T/err")" = "stevedore: name is not printable UTF-8: $(printf "$bad")" ] || fail "name $bad was refused with: $(cat "$T/err")"
done
bad_writer gzip a Distribution
bad_writer none a "$T/nonexistent"
bad_writer none a
rc=0; "$SD" xar --out "$T/bad.xar" none a Distribution 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "xar without --mtime exited $rc, not 2"

same_lines() {
  grep -v -e "<name enctype=\"base64\">" -e "<name>sp ace &amp;" "$1" | LC_ALL=C sort > "$T/l.a"
  grep -v -e "<name enctype=\"base64\">" -e "<name>sp ace &amp;" "$2" | LC_ALL=C sort > "$T/l.b"
  cmp -s "$T/l.a" "$T/l.b" || fail "$3: the TOCs hold different lines: $(diff "$T/l.a" "$T/l.b" | head -6 | tr '\n' '|')"
}
if [ "$(uname -s)" = Darwin ] && command -v xar >/dev/null 2>&1; then
  xar -t -f "$T/product.xar" > "$T/xar-t" || fail "xar -t rejects our archive"
  xar_listing | LC_ALL=C sort > "$T/xar-t.want"
  LC_ALL=C sort "$T/xar-t" | cmp -s - "$T/xar-t.want" || fail "xar -t lists: $(tr '\n' '|' < "$T/xar-t")"
  mkdir "$T/xar-x"
  (cd "$T/xar-x" && xar -x -f "$T/product.xar") || fail "xar -x rejects our archive"
  same_tree "$T/in" "$T/xar-x" "xar -x of our archive"
  xar --dump-toc="$T/dump.toc" -f "$T/product.xar" || fail "xar --dump-toc rejects our archive"
  same_lines "$T/dump.toc" "$T/product.toc" "xar --dump-toc of our archive"
  pkgutil --expand "$T/product.xar" "$T/pkgutil" || fail "pkgutil --expand rejects our archive"
  same_tree "$T/ex" "$T/pkgutil" "stevedore expand vs pkgutil --expand of our archive"
  (cd "$T/in" && xar -c -f "$T/xar-c.xar" base.pkg "$XAR_ODD" Distribution) || fail "xar -c of the inputs failed"
  "$SD" expand "$T/xar-c.xar" "$T/xar-c" || fail "stevedore expand of an archive xar -c made exited $?"
  same_tree "$T/want" "$T/xar-c" "stevedore expand of an archive xar -c made"
fi

if [ "$(uname -s)" = Darwin ] && command -v pkgbuild >/dev/null 2>&1; then
  mkdir "$T/pb-root" "$T/pb-root/sub" "$T/pb-scripts"
  printf 'hello\n' > "$T/pb-root/sub/hello.txt"
  printf '#!/bin/sh\nexit 0\n' > "$T/pb-scripts/postinstall"
  chmod 755 "$T/pb-scripts/postinstall"
  if pkgbuild --root "$T/pb-root" --scripts "$T/pb-scripts" --identifier test.stevedore.xar --version 1 \
       --install-location /tmp/stevedore-xar-test "$T/component.pkg" >/dev/null 2>&1 \
     && productbuild --package "$T/component.pkg" "$T/product.pkg" >/dev/null 2>&1; then
    for name in component product; do
      pkgutil --expand "$T/$name.pkg" "$T/$name.pkgutil" || { fail "pkgutil --expand rejects pkgbuild's $name pkg"; continue; }
      "$SD" expand "$T/$name.pkg" "$T/$name.sd" || { fail "stevedore expand of pkgbuild's $name pkg exited $?"; continue; }
      same_tree "$T/$name.pkgutil" "$T/$name.sd" "stevedore expand vs pkgutil --expand of pkgbuild's $name pkg"
      "$SD" toc "$T/$name.pkg" > "$T/$name.sdtoc" || fail "stevedore toc of pkgbuild's $name pkg exited $?"
      xar --dump-toc="$T/$name.xartoc" -f "$T/$name.pkg" || fail "xar --dump-toc rejects pkgbuild's $name pkg"
      same_lines "$T/$name.xartoc" "$T/$name.sdtoc" "xar --dump-toc vs stevedore toc of pkgbuild's $name pkg"
    done
  else
    fail "could not make pkgbuild and productbuild pkgs to compare with"
  fi
fi

[ "$fails" -eq 0 ] || { echo "xar-test: $fails failure(s)" >&2; exit 1; }
echo "xar-test: ok"
