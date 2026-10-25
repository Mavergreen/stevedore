# platform: host-agnostic
#   usage: . tests/fixtures/xar/inputs.sh; xar_inputs DIR STEVEDORE; (cd DIR/in && xar_write STEVEDORE EPOCH OUT)
#          Builds the product-shaped archive inputs in DIR/in from the staged trees DIR/root and
#          DIR/scripts: a zlib Bom, a Payload holding every byte value, a Scripts archive (both made by
#          stevedore payload), 0-byte files stored and zlib-encoded, and a directory name with a space,
#          UTF-8 and XML metacharacters, each with the mode stevedore expand gives it. xar_listing
#          prints what xar -t lists, in any order.
#          Regenerate tests/fixtures/xar/product.sha256 and product.toc with:
#            T=$(mktemp -d); . tests/fixtures/xar/inputs.sh; xar_inputs $T stevedore
#            (cd $T/in && xar_write stevedore 1700000000 $T/p)
#            sha256sum $T/p | cut -c1-64 > tests/fixtures/xar/product.sha256
#            stevedore toc $T/p > tests/fixtures/xar/product.toc
XAR_ODD='sp ace & <жук>.pkg'
xar_inputs() {
  (
    cd "$1"
    mkdir in in/base.pkg "in/$XAR_ODD" root scripts scripts/lib
    i=0
    while [ "$i" -lt 256 ]; do printf "\\$(printf %03o "$i")"; i=$((i + 1)); done > root/every-byte
    printf '#!/bin/sh\nexit 0\n' > scripts/postinstall
    printf 'helper=1\n' > scripts/lib/helper.sh
    chmod 755 root scripts scripts/lib scripts/postinstall
    chmod 644 root/every-byte scripts/lib/helper.sh
    "$2" payload --root root --mtime 1700000000 --out in/base.pkg/Payload
    "$2" payload --root scripts --mtime 1700000000 --out in/base.pkg/Scripts
    i=0
    while [ "$i" -lt 300 ]; do printf 'BOMStore entry %d of the base package\n' "$i"; i=$((i + 1)); done > in/base.pkg/Bom
    printf '<?xml version="1.0" encoding="utf-8"?>\n<pkg-info identifier="test.base" version="1"/>\n' > in/base.pkg/PackageInfo
    : > in/base.pkg/empty
    : > "in/$XAR_ODD/zero"
    printf '<pkg-info identifier="test.odd"/>\n' > "in/$XAR_ODD/PackageInfo"
    printf '<?xml version="1.0" encoding="utf-8"?>\n<installer-gui-script minSpecVersion="2"/>\n' > in/Distribution
    chmod 644 in/base.pkg/* "in/$XAR_ODD"/* in/Distribution
    chmod 700 in/base.pkg "in/$XAR_ODD"
  )
}
xar_write() {
  "$1" xar --mtime "$2" --out "$3" \
    zlib base.pkg/Bom base.pkg/Bom \
    none base.pkg/Payload base.pkg/Payload \
    none base.pkg/Scripts base.pkg/Scripts \
    zlib base.pkg/PackageInfo base.pkg/PackageInfo \
    none base.pkg/empty base.pkg/empty \
    zlib "$XAR_ODD/zero" "$XAR_ODD/zero" \
    zlib "$XAR_ODD/PackageInfo" "$XAR_ODD/PackageInfo" \
    zlib Distribution Distribution
}
xar_listing() {
  printf '%s\n' base.pkg base.pkg/Bom base.pkg/Payload base.pkg/Scripts base.pkg/PackageInfo base.pkg/empty \
    "$XAR_ODD" "$XAR_ODD/zero" "$XAR_ODD/PackageInfo" Distribution
}
