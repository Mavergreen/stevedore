# platform: host-agnostic
#   usage: . tests/fixtures/component/build.sh; component_fixtures DIR; component_fixture STEVEDORE DIR NAME OUT
#          component_fixtures builds the basic, bundles and scripts trees in DIR (the trees/*.sh
#          functions must be loaded). component_fixture packages DIR/NAME, with DIR/scripts for the
#          basic tree, as the golden fixtures record it.
component_fixtures() {
  mkdir "$1/basic" "$1/bundles" "$1/scripts"
  basic_tree "$1/basic"
  bundles_tree "$1/bundles" "$FX/plist/app.binary1.plist"
  scripts_tree "$1/scripts"
}

component_fixture() {
  set -- "$1" "$2" "$3" "$4" --root "$2/$3" --identifier "dev.mavergreen.stevedore-test.$3" --version 1.0 \
    --install-location "/Library/Stevedore Test/$3" --mtime 1672574400 --out "$4"
  [ "$3" != basic ] || set -- "$@" --scripts "$2/scripts"
  _cf_sd="$1"
  shift 4
  "$_cf_sd" component "$@"
}
