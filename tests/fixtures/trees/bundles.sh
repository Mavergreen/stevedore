# platform: host-agnostic
#   usage: . tests/fixtures/trees/bundles.sh; bundles_tree DIR BINARY1_PLIST
#          Builds a staged tree of bundles in the empty directory DIR: an updater-shaped .app whose
#          Info.plist is BINARY1_PLIST (binary1), holding a versioned Sparkle-shaped framework whose
#          Resources reach Versions/A through symlinks and which holds its own Autoupdate.app; a plugin
#          whose version.plist overrides an integer CFBundleVersion; a flat bundle; a framework whose
#          Info.plist is in Resources, not Contents; a bundle whose path and identifier carry XML
#          metacharacters; and a Contents/Info.plist without CFBundleIdentifier, which is no bundle.
#          Every mode and mtime (2023-01-01 12:00 UTC) is set explicitly.
bundles_plist() {
  mkdir -p "$(dirname "$1")"
  f="$1"; shift
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n'
    while [ "$#" -gt 0 ]; do
      printf '\t<key>%s</key>\n\t%s\n' "$1" "$2"
      shift 2
    done
    printf '</dict>\n</plist>\n'
  } > "$f"
}

bundles_tree() {
  (
    cd "$1"
    app='Library/Application Support/Mavergreen/t-updater.app'
    fw="$app/Contents/Frameworks/Sparkle.framework"
    mkdir -p "$app/Contents/MacOS" "$fw/Versions/A/Resources" var/empty
    cp "$2" "$app/Contents/Info.plist"
    printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/t-updater"
    bundles_plist "$fw/Versions/A/Resources/Info.plist" \
      CFBundleIdentifier '<string>org.sparkle-project.Sparkle</string>' \
      CFBundleShortVersionString '<string>1.27.3</string>' CFBundleVersion '<string>1.108</string>'
    printf 'not really a dylib\n' > "$fw/Versions/A/Sparkle"
    ln -s A "$fw/Versions/Current"
    ln -s Versions/Current/Resources "$fw/Resources"
    ln -s Versions/Current/Sparkle "$fw/Sparkle"
    au="$fw/Versions/A/Resources/Autoupdate.app/Contents"
    bundles_plist "$au/Info.plist" \
      CFBundleIdentifier '<string>org.sparkle-project.Sparkle.Autoupdate</string>' \
      CFBundleShortVersionString '<string>1.27.3</string>' CFBundleVersion '<string>1.108</string>'
    mkdir "$au/MacOS"
    printf '#!/bin/sh\nexit 0\n' > "$au/MacOS/Autoupdate"
    bundles_plist 'Library/Plug-ins/T.plugin/Contents/Info.plist' \
      CFBundleIdentifier '<string>dev.mavergreen.test.plugin</string>' CFBundleVersion '<integer>7</integer>'
    bundles_plist 'Library/Plug-ins/T.plugin/Contents/version.plist' \
      CFBundleVersion '<string>7.0.1</string>' SourceVersion '<string>70001000000000</string>' \
      BuildVersion '<string>3</string>' ProjectName '<string>T</string>'
    bundles_plist 'Library/Flat.bundle/Info.plist' CFBundleIdentifier '<string>dev.mavergreen.test.flat</string>'
    bundles_plist 'Library/Frameworks/Old.framework/Resources/Info.plist' \
      CFBundleIdentifier '<string>dev.mavergreen.test.old</string>' CFBundleShortVersionString '<string>2</string>'
    bundles_plist 'Library/Sp&c <x>.bundle/Contents/Info.plist' \
      CFBundleIdentifier '<string>a&amp;b&lt;c&gt;"d'"'"'é</string>' CFBundleVersion '<string>1&amp;"2</string>'
    bundles_plist 'lib/NotABundle/Contents/Info.plist' CFBundleName '<string>NotABundle</string>'
    printf 'readme\n' > README
    find . -type d -exec chmod 755 {} +
    find . -type f -exec chmod 644 {} +
    chmod 755 "$app/Contents/MacOS/t-updater" "$au/MacOS/Autoupdate"
    find . -exec env TZ=UTC touch -h -t 202301011200 {} +
  )
}
