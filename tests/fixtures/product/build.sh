# platform: host-agnostic
#   usage: . tests/fixtures/product/build.sh; product_inputs STEVEDORE DIR [BASE-ID PRODUCT-ID LOCATION]
#          product_fixture STEVEDORE DIR OUT [FLOOR]
#          product_inputs builds in the empty directory DIR a base-like component (DIR/pkgs/mavergreen-base.pkg)
#          and the bundles tree as the product component (DIR/pkgs/product.pkg), each with a preinstall
#          and a postinstall that append "<base|product> <script>" to the order file beside their
#          install location, the Resources directory DIR/res (welcome, license and conclusion, and a
#          file nothing references) and DIR/distribution.xml, which is distribution.xml here with the
#          identifiers replaced. The defaults are the golden fixture's: dev.mavergreen.base,
#          dev.mavergreen.stevedore-test.product and "/Library/Stevedore Test". The trees/*.sh
#          functions must be loaded. product_fixture writes the product from them, with the
#          os-version floor replaced by FLOOR when given.
product_inputs() {
  _pi_sd="$1"; _pi_d="$2"
  _pi_base="${3:-dev.mavergreen.base}"; _pi_prod="${4:-dev.mavergreen.stevedore-test.product}"
  _pi_loc="${5:-/Library/Stevedore Test}"
  mkdir "$_pi_d/base" "$_pi_d/base/bin" "$_pi_d/base/share" "$_pi_d/product" "$_pi_d/res" "$_pi_d/pkgs"
  printf '#!/bin/sh\necho tool\n' > "$_pi_d/base/bin/tool"
  printf 'base\n' > "$_pi_d/base/share/readme"
  chmod 755 "$_pi_d/base" "$_pi_d/base/bin" "$_pi_d/base/share" "$_pi_d/base/bin/tool"
  chmod 644 "$_pi_d/base/share/readme"
  bundles_tree "$_pi_d/product" "$FX/plist/app.binary1.plist"
  for _pi_k in base product; do
    mkdir "$_pi_d/$_pi_k-scripts"
    for _pi_s in preinstall postinstall; do
      printf '#!/bin/sh\nprintf "%%s\\n" "%s %s" >> "$(dirname "$2")/order"\n' "$_pi_k" "$_pi_s" > "$_pi_d/$_pi_k-scripts/$_pi_s"
    done
    chmod 755 "$_pi_d/$_pi_k-scripts" "$_pi_d/$_pi_k-scripts"/*
  done
  printf '<html><body>Welcome</body></html>\n' > "$_pi_d/res/welcome.html"
  printf 'Public domain.\n' > "$_pi_d/res/license.txt"
  printf '<html><body>Done</body></html>\n' > "$_pi_d/res/conclusion.html"
  printf 'nothing references this\n' > "$_pi_d/res/unreferenced.txt"
  chmod 755 "$_pi_d/res"
  chmod 644 "$_pi_d/res"/*
  find "$_pi_d/base" "$_pi_d/base-scripts" "$_pi_d/product-scripts" "$_pi_d/res" -exec env TZ=UTC touch -h -t 202301011200 {} +
  "$_pi_sd" component --root "$_pi_d/base" --identifier "$_pi_base" --version 1.0.5 --install-location "$_pi_loc/base" \
    --scripts "$_pi_d/base-scripts" --mtime 1672574400 --out "$_pi_d/pkgs/mavergreen-base.pkg" || return
  "$_pi_sd" component --root "$_pi_d/product" --identifier "$_pi_prod" --version 2.0 --install-location "$_pi_loc/product" \
    --scripts "$_pi_d/product-scripts" --mtime 1672574400 --out "$_pi_d/pkgs/product.pkg" || return
  sed -e "s/dev\.mavergreen\.stevedore-test\.product/$_pi_prod/g" -e "s/dev\.mavergreen\.base/$_pi_base/g" \
    "$FX/product/distribution.xml" > "$_pi_d/distribution.xml"
}

product_fixture() {
  _pf_dist="$2/distribution.xml"
  if [ -n "${4:-}" ]; then
    sed "s/os-version min=\"[^\"]*\"/os-version min=\"$4\"/" "$2/distribution.xml" > "$2/distribution-$4.xml"
    _pf_dist="$2/distribution-$4.xml"
  fi
  "$1" product --distribution "$_pf_dist" --package "$2/pkgs/mavergreen-base.pkg" --package "$2/pkgs/product.pkg" \
    --resources "$2/res" --mtime 1672574400 --out "$3"
}
