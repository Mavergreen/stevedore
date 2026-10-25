# platform: macOS-only -- sw_vers names the oracle host
#   usage: . tests/fixtures/oracle/normalize.sh
#          oracle_reconcile PKGBUILD_XML STEVEDORE_XML OUT_PKGBUILD OUT_STEVEDORE writes both files
#          with what pkgbuild or productbuild may vary removed, so the comparison stays exact elsewhere:
#            - &gt; becomes > (modern tools escape it, 10.9's do not; the XML is the same);
#            - a bundle element of stevedore's drops BuildVersion when the tool's element for the same
#              path has none (stevedore's bundle attributes are a superset: modern tools omit it);
#            - on macOS 11 or later only, standalone="no" leaves the XML declaration and installKBytes
#              reads as "*" (APFS sizes directories otherwise than the HFS+ rule stevedore writes).
oracle_reconcile() {
  _modern=0
  [ "$(sw_vers -productVersion | cut -d. -f1)" = 10 ] || _modern=1
  awk -v modern="$_modern" -v out1="$3" -v out2="$4" '
    function clean(l) {
      gsub(/&gt;/, ">", l)
      if (modern) { sub(/ standalone="no"\?>/, "?>", l); sub(/ installKBytes="[0-9]*"/, " installKBytes=\"*\"", l) }
      return l
    }
    function path(l) { return match(l, / path="[^"]*"/) ? substr(l, RSTART, RLENGTH) : "" }
    NR == FNR { l = clean($0); print l > out1; if (l ~ /<bundle / && path(l) != "") bv[path(l)] = (l ~ / BuildVersion="/); next }
    { l = clean($0); p = path(l); if (l ~ /<bundle / && (p in bv) && !bv[p]) sub(/ BuildVersion="[^"]*"/, "", l); print l > out2 }' "$1" "$2"
}
