# platform: host-agnostic
#   usage: . tests/fixtures/trees/scripts.sh; scripts_tree DIR
#          Builds a --scripts directory in the empty directory DIR: preinstall and postinstall, each
#          appending its name to INSTALL_LOCATION.scripts-ran, a helper in a subdirectory, and a
#          preflight, which is not a script pkgbuild runs. Modes and mtimes (2023-01-01 12:00 UTC) are
#          set explicitly.
scripts_tree() {
  (
    cd "$1"
    mkdir lib
    printf '#!/bin/sh\n. "$(dirname "$0")/lib/helper.sh"\nran preinstall "$2"\n' > preinstall
    printf '#!/bin/sh\n. "$(dirname "$0")/lib/helper.sh"\nran postinstall "$2"\n' > postinstall
    printf 'ran() { printf "%%s\\n" "$1" >> "${2%%/}.scripts-ran"; }\n' > lib/helper.sh
    printf '#!/bin/sh\nexit 1\n' > preflight
    chmod 755 . lib preinstall postinstall preflight
    chmod 644 lib/helper.sh
    find . -exec env TZ=UTC touch -h -t 202301011200 {} +
  )
}
