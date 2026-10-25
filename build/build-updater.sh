#!/bin/sh
# platform: macOS-only -- builds a Cocoa app with Apple's clang, as shipyard's updater recipe requires
#   usage: sh build/build-updater.sh
#          Builds updater/ into stevedore-updater.app and prints its path: x86_64 10.9 and, on macOS 11 or
#          later, arm64 11.0 too, merged into one app. Needs ./VERSION.
# spec: INGREDIENTS.md "Conformance deviations", arm64 -- the pkg installs on Apple Silicon, where an
#       x86_64-only updater prompts for Rosetta
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
STEVEDORE_ROOT="$(dirname "$SELF")"
. "$SELF/lib.sh"
. "$SELF/msc.sh"
[ -s "$STEVEDORE_ROOT/VERSION" ] || { echo "build-updater: no VERSION file; the release workflow's ver job writes it" >&2; exit 1; }
SC="$(command -v shipyard-cmake || echo /usr/local/mavergreen/bin/shipyard-cmake)"
TC="$(dirname "$SHIPYARD_SCRIPTS")/MavericksToolchain.cmake"
W="$(stevedore_build_root)/$(basename "$STEVEDORE_ROOT")-updater"
major="$(sw_vers -productVersion | cut -d. -f1)"
slices="x86_64:10.9"; [ "$major" -ge 11 ] && slices="x86_64:10.9 arm64:11.0"
for s in $slices; do
  a="${s%%:*}"; floor="${s#*:}"
  OBJC=/usr/bin/clang "$SC" -S "$STEVEDORE_ROOT/updater" -B "$W/$a" -DCMAKE_OBJC_COMPILER=/usr/bin/clang \
    -DCMAKE_OSX_ARCHITECTURES="$a" -DCMAKE_OSX_DEPLOYMENT_TARGET="$floor" -DCMAKE_TOOLCHAIN_FILE="$TC" >&2
  "$SC" --build "$W/$a" >&2
  [ -d "$W/$a/stevedore-updater.app" ] || { echo "build-updater: no stevedore-updater.app under $W/$a" >&2; exit 1; }
done
out="$W/merged/stevedore-updater.app"
rm -rf "$W/merged"; mkdir -p "$W/merged"
if [ "$major" -ge 11 ]; then
  sh "$SHIPYARD_SCRIPTS/lipo-merge-tree.sh" --a "$W/x86_64/stevedore-updater.app" \
    --b "$W/arm64/stevedore-updater.app" --out "$out" --require-archs "x86_64 arm64" >&2
else
  cp -R "$W/x86_64/stevedore-updater.app" "$out"
fi
printf '%s\n' "$out"
