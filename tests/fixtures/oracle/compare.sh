# platform: macOS-only -- pkgutil, xar and sw_vers (normalize.sh) read the products
#   usage: . tests/fixtures/oracle/normalize.sh; . tests/fixtures/oracle/compare.sh   (T is a scratch directory, fail a function)
#          same_component WHAT PB-EXPANDED SD-EXPANDED compares two pkgutil --expand'ed component pkgs: names, BOM,
#          payload listing, Scripts (but the mtime of Scripts itself, which pkgutil sets to the time it expands) and PackageInfo. same_products WHAT PRODUCTBUILD-PKG STEVEDORE-PKG (with SAME_COMPONENTS=1, the nested component pkgs are compared by same_component, not byte for byte, and in any xar order) calls fail for each way the stevedore product differs
#          from the productbuild one beyond what normalize.sh and canon (bundle order, updateKBytes="0") reconcile.
canon() {
  awk '
    function attrs(line,   pre, rest, n, a, i, j, t, out) {
      match(line, /^ *<bundle/); pre = substr(line, 1, RLENGTH); rest = substr(line, RLENGTH + 1); n = 0
      while (match(rest, /^ [A-Za-z][A-Za-z-]*="[^"]*"/)) { a[++n] = substr(rest, 2, RLENGTH - 1); rest = substr(rest, RLENGTH + 1) }
      for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t }
      out = pre
      for (i = 1; i <= n; i++) out = out " " a[i]
      return out rest
    }
    function flush(   i, j, t) {
      for (i = 2; i <= nb; i++) { t = b[i]; for (j = i - 1; j >= 1 && b[j] > t; j--) b[j + 1] = b[j]; b[j + 1] = t }
      for (i = 1; i <= nb; i++) print b[i]
      nb = 0
    }
    /^ *<bundle / { b[++nb] = attrs($0); next }
    { flush(); if ($0 ~ /^ *<pkg-ref /) sub(/ updateKBytes="0"/, ""); print }
    END { flush() }' "$1"
}

toc_shape() {
  xar --dump-toc="$2" -f "$1" || return
  awk '
    /<file / { d++; name[d] = ""; type[d] = ""; enc[d] = "" }
    d && /<name>/ && name[d] == "" { s = $0; sub(/^ *<name>/, "", s); sub(/<\/name>$/, "", s); name[d] = s }
    d && /<type>/ { s = $0; sub(/^ *<type>/, "", s); sub(/<\/type>$/, "", s); type[d] = s }
    d && /<encoding / { s = $0; sub(/^ *<encoding style="/, "", s); sub(/".*/, "", s); enc[d] = s }
    /<\/file>/ { p = ""; for (i = 1; i <= d; i++) p = p "/" name[i]; print p, type[d], enc[d]; d-- }' "$2"
}

same_products() {
  what="$1"; pb="$2"; sd="$3"
  for k in pb sd; do rm -rf "$T/$k.x"; done
  pkgutil --expand "$pb" "$T/pb.x" || { fail "$what: pkgutil --expand rejects the productbuild product"; return 1; }
  pkgutil --expand "$sd" "$T/sd.x" || { fail "$what: pkgutil --expand rejects the stevedore product"; return 1; }
  xar -tf "$pb" > "$T/pb.t"; xar -tf "$sd" > "$T/sd.t"
  if [ -n "${SAME_COMPONENTS:-}" ]; then
    for k in pb sd; do LC_ALL=C sort "$T/$k.t" > "$T/$k.t.s"; mv "$T/$k.t.s" "$T/$k.t"; done
  fi
  cmp -s "$T/pb.t" "$T/sd.t" || fail "$what: xar -t lists other names or another order: $(diff "$T/pb.t" "$T/sd.t" | tr '\n' '|')"
  toc_shape "$pb" "$T/pb.dump" > "$T/pb.shape"; toc_shape "$sd" "$T/sd.dump" > "$T/sd.shape"
  if [ -n "${SAME_COMPONENTS:-}" ]; then
    for k in pb sd; do LC_ALL=C sort "$T/$k.shape" > "$T/$k.shape.s"; mv "$T/$k.shape.s" "$T/$k.shape"; done
  fi
  cmp -s "$T/pb.shape" "$T/sd.shape" || fail "$what: xar --dump-toc shows other names, types or encodings: $(diff "$T/pb.shape" "$T/sd.shape" | tr '\n' '|')"
  (cd "$T/pb.x" && find . | LC_ALL=C sort) > "$T/pb.list"
  (cd "$T/sd.x" && find . | LC_ALL=C sort) > "$T/sd.list"
  cmp -s "$T/pb.list" "$T/sd.list" || { fail "$what: the expanded products hold other names: $(diff "$T/pb.list" "$T/sd.list" | tr '\n' '|')"; return 1; }
  while IFS= read -r p; do
    [ "$p" != ./Distribution ] || continue
    [ "$(ls -ld "$T/pb.x/$p" | cut -c1-10)" = "$(ls -ld "$T/sd.x/$p" | cut -c1-10)" ] || fail "$what: $p has another mode"
    [ -f "$T/pb.x/$p" ] && ! [ -h "$T/pb.x/$p" ] || continue
    case "$p" in ./*.pkg/*) [ -z "${SAME_COMPONENTS:-}" ] || continue ;; esac
    cmp -s "$T/pb.x/$p" "$T/sd.x/$p" || fail "$what: $p differs"
  done < "$T/pb.list"
  if [ -n "${SAME_COMPONENTS:-}" ]; then
    for c in $(cd "$T/pb.x" && ls -d ./*.pkg); do same_component "$what: $c" "$T/pb.x/$c" "$T/sd.x/$c"; done
  fi
  oracle_reconcile "$T/pb.x/Distribution" "$T/sd.x/Distribution" "$T/pb.dist" "$T/sd.dist"
  canon "$T/pb.dist" > "$T/pb.canon"; canon "$T/sd.dist" > "$T/sd.canon"
  cmp -s "$T/pb.canon" "$T/sd.canon" || fail "$what: the Distributions differ beyond bundle order, updateKBytes and oracle_reconcile: $(diff "$T/pb.canon" "$T/sd.canon" | head -12 | tr '\n' '|')"
  [ "$(tail -c 1 "$T/pb.x/Distribution")" = "$(tail -c 1 "$T/sd.x/Distribution")" ] || fail "$what: the Distributions end differently"
}

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

same_component() {
  (cd "$2" && find . | LC_ALL=C sort) > "$T/pb.list"
  (cd "$3" && find . | LC_ALL=C sort) > "$T/sd.list"
  cmp -s "$T/pb.list" "$T/sd.list" || fail "$1: the expanded pkgs hold other names: $(diff "$T/pb.list" "$T/sd.list" | tr '\n' '|')"
  for o in "-p MUGsTfc" "" "-s"; do
    TZ=UTC lsbom $o "$2/Bom" > "$T/pb.out"
    TZ=UTC lsbom $o "$3/Bom" > "$T/sd.out"
    cmp -s "$T/pb.out" "$T/sd.out" || fail "$1: lsbom $o differs: $(diff "$T/pb.out" "$T/sd.out" | head -6 | tr '\n' '|')"
  done
  gzip -dc < "$2/Payload" | TZ=UTC cpio -itv 2>/dev/null | LC_ALL=C sort > "$T/pb.out"
  gzip -dc < "$3/Payload" | TZ=UTC cpio -itv 2>/dev/null | LC_ALL=C sort > "$T/sd.out"
  cmp -s "$T/pb.out" "$T/sd.out" || fail "$1: the payload listings differ: $(diff "$T/pb.out" "$T/sd.out" | head -6 | tr '\n' '|')"
  if [ -d "$2/Scripts" ]; then
    (cd "$2/Scripts" && find . -exec stat -f '%Sp %z %m %N%SY' {} + | sed 's/^\([^ ]* [^ ]*\) [0-9]* \.$/\1 ./' | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort) > "$T/pb.out"
    (cd "$3/Scripts" && find . -exec stat -f '%Sp %z %m %N%SY' {} + | sed 's/^\([^ ]* [^ ]*\) [0-9]* \.$/\1 ./' | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort) > "$T/sd.out"
    cmp -s "$T/pb.out" "$T/sd.out" || fail "$1: the expanded Scripts differ: $(diff "$T/pb.out" "$T/sd.out" | head -6 | tr '\n' '|')"
  fi
  oracle_reconcile "$2/PackageInfo" "$3/PackageInfo" "$T/pb.pi" "$T/sd.pi"
  normalize "$T/pb.pi" > "$T/pb.out"
  normalize "$T/sd.pi" > "$T/sd.out"
  cmp -s "$T/pb.out" "$T/sd.out" || fail "$1: the PackageInfos differ beyond generator-version, timeout, order and oracle_reconcile: $(diff "$T/pb.out" "$T/sd.out" | head -12 | tr '\n' '|')"
}
