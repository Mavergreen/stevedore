#!/bin/sh
# platform: host-agnostic
# usage: sh tests/release-workflow-test.sh
#   .github/workflows/release.yml keeps the release shape: a push builds and never publishes, a dispatch on main
#   does; publish waits for the package job and for the 10.9 on-target job, which installs this run's pkg in
#   mavericks-vm and runs every suite against the stevedore it installed; both run once per same-repo PR head
#   (its branch push), and on a fork's or Renovate's PR; the Linux tarball is
#   opt/mavergreen/stevedore/ alone and passes shipyard's product-archive reader; no run: block holds ${{ }}; no
#   job anywhere runs on a macOS runner without a macos-runner:<job> deviation; and an ingredient in INGREDIENTS.md's
#   Declared state is exactly what repackage-on-ingredient-bump.yml watches. Each check is shown to refuse a
#   mutated copy. The package job also builds the Sparkle updater into the pkg and signs it, and a key scan precedes
#   publish. The package job runs the pkgbuild and productbuild oracles with the pinned stevedore before it packages
#   with it, INGREDIENTS.md no longer gives the bootstrap as a reason for the macOS runner, and the stevedore
#   self-pin is declared as a deviation and is in no ingredient list, trigger, bot or Renovate manager.
#   The package job compares its pkg with pkgbuild and productbuild (build/oracle-pkg.sh), and the macOS-runner deviation names every macOS dependency.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/release-workflow.XXXXXX")"
trap 'rm -rf "$T"' EXIT
W="$REPO/.github/workflows/release.yml"
R="$REPO/.github/workflows/repackage-on-ingredient-bump.yml"
I="$REPO/INGREDIENTS.md"
for f in "$W" "$R" "$I"; do [ -f "$f" ] || fail "$f does not exist"; done

job() {  # job <workflow> <name> -- the job's lines
  awk -v j="  $2:" '$0 == j { on = 1; next } on && /^  [a-z]/ { exit } on { print }' "$1"
}

macos_jobs() {  # macos_jobs <workflow>... -- the jobs that run on a macOS runner, one per line
  for _w in "$@"; do
    awk '/^jobs:/ { in_jobs = 1; next } in_jobs && /^  [a-z][a-z0-9_-]*:$/ { j = substr($1, 1, length($1) - 1) }
      in_jobs && j && /^    runs-on: *macos/ { print j }' "$_w"
  done
}

# platform: shape <release.yml> <repackage caller> <INGREDIENTS.md> prints the first invariant they break, and fails.
shape() {
  _on="$(awk '/^on:/ { on = 1; next } on && /^[^ #]/ { exit } on && /^  [a-z_]+:/ { print $1 }' "$1" | tr '\n' ' ')"
  [ "$_on" = "push: pull_request: workflow_dispatch: " ] || { echo "on: is not push, pull_request and workflow_dispatch: [$_on]"; return 1; }
  grep -qx "    branches-ignore: \['renovate/\*\*'\]" "$1" || { echo "push does not build every branch but Renovate's"; return 1; }
  for _j in package on-target; do
    [ "$(job "$1" "$_j" | grep -c '^    if: ')" = 1 ] \
      && job "$1" "$_j" | grep -qxF "    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name != github.repository || startsWith(github.head_ref, 'renovate/')" \
      || { echo "the $_j job does not skip a same-repo PR's second run while running a fork's and Renovate's"; return 1; }
  done
  job "$1" ver > "$T/ver"
  [ "$(grep -c 'pub=yes' "$T/ver")" = 2 ] \
    && grep -qxF '          if [ "$GITHUB_REF" = refs/heads/main ] && [ "$GITHUB_EVENT_NAME" = workflow_dispatch ]; then' "$T/ver" \
    && [ "$(awk '/pub=no/ { n = NR } /pub=yes/ { y = NR } END { print (n && y > n) }' "$T/ver")" = 1 ] \
    || { echo "the ver job can publish from something other than a dispatch on main"; return 1; }
  job "$1" publish > "$T/publish"
  grep -qx '    needs: \[ver, package, on-target, scan\]' "$T/publish" \
    || { echo "publish does not wait for the package, on-target and key-scan jobs"; return 1; }
  job "$1" scan > "$T/scan"
  grep -qx '    uses: Mavergreen/shipyard/.github/workflows/scan-for-key.yml@v1' "$T/scan" \
    && grep -qxF "    if: always() && needs.ver.outputs.publish == 'yes' && github.ref == 'refs/heads/main'" "$T/scan" \
    || { echo "the key scan is not shipyard's, run whenever a publishing run signed"; return 1; }
  grep -qxF "    if: needs.ver.outputs.publish == 'yes' && github.ref == 'refs/heads/main'" "$T/publish" \
    || { echo "publish does not ask for the ver job's yes on main"; return 1; }
  grep -qx '    uses: Mavergreen/shipyard/.github/workflows/publish-release.yml@v1' "$T/publish" \
    || { echo "publish is not shipyard's publish-release.yml"; return 1; }
  job "$1" on-target > "$T/on-target"
  grep -qx '        uses: Mavergreen/mavericks-vm@v1' "$T/on-target" \
    && grep -qF 'sudo installer -pkg "dist/stevedore-$V.pkg" -target /' "$T/on-target" \
    && grep -qF 'STEVEDORE="$SD" STEVEDORE_BUILD="$PWD/sd"' "$T/on-target" \
    && grep -qF 'run-repo-tests.sh --strict-host' "$T/on-target" \
    || { echo "on-target does not install this run's pkg on 10.9 and run the suites against what it installed"; return 1; }
  job "$1" package > "$T/package"
  grep -qF 'sh build/package-pkg.sh "$RUNNER_TEMP/stevedore"' "$T/package" \
    && grep -qF 'llvm-lipo" -create' "$T/package" \
    && grep -qF 'MAVERICKS_ALLOW_ARCHS: x86_64 arm64' "$T/package" \
    || { echo "the package job does not merge both slices, guard them and package them"; return 1; }
  grep -qF 'STEVEDORE="$(sh build/fetch-stevedore.sh)/bin/stevedore"' "$T/package" \
    && grep -qF 'sh tests/component-oracle-test.sh' "$T/package" \
    && grep -qF 'sh tests/product-oracle-test.sh' "$T/package" \
    && grep -qF 'STEVEDORE_ORACLE: 1' "$T/package" \
    && grep -qF 'echo "SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)" >> "$GITHUB_ENV"' "$T/package" \
    && [ -f "$REPO/build/oracle-pkg.sh" ] \
    && grep -qF 'sh "$SELF/oracle-pkg.sh"' "$REPO/build/package-pkg.sh" \
    && [ "$(awk '/product-oracle-test.sh/ { o = NR } /build\/package-pkg.sh/ { p = NR } END { print (o && p > o) }' "$T/package")" = 1 ] \
    || { echo "the package job does not run the oracles with the pinned stevedore before it packages with it"; return 1; }
  grep -qF 'app="$(sh build/build-updater.sh)"' "$T/package" \
    && grep -qF 'sh build/package-pkg.sh "$RUNNER_TEMP/stevedore" "$STEVEDORE_UPDATER"' "$T/package" \
    && grep -qF 'sh "$SHIPYARD_SCRIPTS/sign_and_appcast.sh" --product stevedore --feed-dir dist' "$T/package" \
    && grep -qF 'sh "$SHIPYARD_SCRIPTS/stand-in-feeds.sh" dist "$VER"' "$T/package" \
    || { echo "the package job does not build the updater into the pkg and sign it, or stand in its feed"; return 1; }
  job "$1" build-linux > "$T/linux"
  grep -qF 'opt/mavergreen/stevedore/bin/stevedore > "$RUNNER_TEMP/want"' "$T/linux" \
    && grep -qF 'python3 "$SHIPYARD_SCRIPTS/product-tar.py" "$STEVEDORE_TARBALL" stevedore' "$T/linux" \
    || { echo "the Linux tarball is not checked to be opt/mavergreen/stevedore/ alone and readable by shipyard"; return 1; }
  _run="$(awk 'function ind(l) { match(l, /^ */); return RLENGTH }
    r && (/^ *$/ || ind($0) > ri) { if (index($0, "${{")) print NR ": " $0; next }
    { r = 0 }
    /^ *(- )?run:/ { ri = ind($0); r = 1; if (index($0, "${{")) print NR ": " $0 }' "$1")"
  [ -z "$_run" ] || { echo "a run: block holds \${{ }}: $_run"; return 1; }
  for _j in $(macos_jobs "$1" "$REPO/.github/workflows/ci.yml"); do
    grep -q "^- macos-runner:$_j: ." "$3" || { echo "the $_j job runs on macOS with no macos-runner:$_j deviation"; return 1; }
  done
  _pkgdev="$(sed -n 's/^- macos-runner:package: //p' "$3")"
  case "$_pkgdev" in *ootstrap*|*"before its first release"*|*"pkgbuild and productbuild through"*) echo "macos-runner:package still gives the bootstrap as a reason"; return 1 ;; esac
  for _r in "arm64 slice" "Sparkle updater" PlistBuddy "pkgutil --expand-full" "build/oracle-pkg.sh" Installer; do
    case "$_pkgdev" in *"$_r"*) ;; *) echo "macos-runner:package does not name its macOS dependency [$_r]"; return 1 ;; esac
  done
  case "$_pkgdev" in *exit:*exit:*exit:*exit:*exit:*exit:*) ;; *) echo "macos-runner:package does not give each reason an exit"; return 1 ;; esac
  grep -q '^- self-pin:stevedore: .*[Rr]evisit if' "$3" || { echo "no self-pin:stevedore deviation with its revisit trigger"; return 1; }
  ! sed -n '/^## Declared state/,/^## /p' "$3" | grep -q 'components/stevedore' \
    && ! grep -q 'components/stevedore' "$2" "$REPO/.github/renovate.json" "$REPO/.github/workflows/pins-bot.yml" \
    || { echo "the stevedore self-pin is declared, watched, bot-managed or Renovate-tracked, so a bump would release again"; return 1; }
  _declared="$(sed -n '/^## Declared state/,/^## /p' "$3" | sed -n 's/^- [a-z0-9-]*: \(components\/.*\)$/\1/p' | LC_ALL=C sort)"
  _watched="$(sed -n 's/^      - \(components\/.*\)$/\1/p' "$2" | LC_ALL=C sort)"
  [ -n "$_declared" ] && [ "$_declared" = "$_watched" ] \
    || { echo "repackage-on-ingredient-bump.yml watches [$(echo $_watched)], not the declared ingredients [$(echo $_declared)]"; return 1; }
}
shape "$W" "$R" "$I" > "$T/out" || fail "$(cat "$T/out")"

mutant() {  # mutant <what it breaks> <expected message> <file: W, R or I> <sed script> -- shape must refuse it
  case "$3" in W) _src="$W" ;; R) _src="$R" ;; I) _src="$I" ;; esac
  sed "$4" "$_src" > "$T/mutant"
  if cmp -s "$_src" "$T/mutant"; then fail "mutant '$1' changed nothing"; fi
  case "$3" in
    W) shape "$T/mutant" "$R" "$I" > "$T/out" && fail "shape passed $1" ;;
    R) shape "$W" "$T/mutant" "$I" > "$T/out" && fail "shape passed $1" ;;
    I) shape "$W" "$R" "$T/mutant" > "$T/out" && fail "shape passed $1" ;;
  esac
  grep -qF "$2" "$T/out" || fail "shape, $1: said [$(cat "$T/out")]"
  echo "   refused: $1"
}
mutant "a tag trigger" "on: is not push" W 's/^  pull_request:$/  release:\
  pull_request:/'
mutant "push on main only" "every branch but Renovate's" W "s|branches-ignore: \['renovate/\*\*'\]|branches: [main]|"
mutant "a package job that runs twice per PR" "the package job does not skip" W '/^  package:$/,/^  on-target:$/{/^    if: github.event_name/d;}'
mutant "an on-target job that runs twice per PR" "the on-target job does not skip" W '/^  on-target:$/,/^  publish:$/{/^    if: github.event_name/d;}'
mutant "Renovate PRs left unpackaged" "does not skip a same-repo PR" W "s/ || startsWith(github.head_ref, 'renovate\/')//"
mutant "a push to main that publishes" "other than a dispatch on main" W 's/ && \[ "$GITHUB_EVENT_NAME" = workflow_dispatch \]//'
mutant "a dispatch on any ref" "other than a dispatch on main" W 's/\[ "$GITHUB_REF" = refs\/heads\/main \] && //'
mutant "a publish decided before the guard" "other than a dispatch on main" W 's/^          pub=no$/          pub=yes/'
mutant "a publish without the 10.9 job" "does not wait" W 's/^    needs: \[ver, package, on-target, scan\]$/    needs: [ver, package, scan]/'
mutant "a publish without the key scan" "does not wait" W 's/^    needs: \[ver, package, on-target, scan\]$/    needs: [ver, package, on-target]/'
mutant "a scan skipped after a failed signing run" "the key scan is not" W "s/^    if: always() \&\& needs.ver/    if: needs.ver/"
mutant "a pkg without the updater" "does not build the updater" W 's/"$RUNNER_TEMP\/stevedore" "$STEVEDORE_UPDATER"/"$RUNNER_TEMP\/stevedore"/'
mutant "an unsigned release" "does not build the updater" W '/sign_and_appcast.sh" --product stevedore/d'
mutant "a publish off main" "yes on main" W "/^  publish:\$/,\$s/ \&\& github.ref == 'refs\/heads\/main'//"
mutant "a hand-rolled publish" "is not shipyard's" W 's|publish-release.yml@v1|publish-release.yml@main|'
mutant "an on-target that installs nothing" "does not install this run's pkg" W '/sudo installer -pkg "dist\/stevedore-$V.pkg"/d'
mutant "an on-target that tests the build, not the pkg" "does not install this run's pkg" W 's/STEVEDORE="$SD" STEVEDORE_BUILD/STEVEDORE_BUILD/'
mutant "a packager that is not checked against the oracles" "does not run the oracles" W '/sh tests\/product-oracle-test.sh/d'
mutant "the bootstrap reason kept" "still gives the bootstrap" I 's/for six reasons\. (1)/for six reasons. The packager cannot package itself before its first release. (1)/'
mutant "the updater reason dropped" "does not name its macOS dependency" I 's/Sparkle updater is built there/Sparkle thing is built there/'
mutant "the oracle comparison dropped from the deviation" "does not name its macOS dependency" I 's/build\/oracle-pkg.sh builds/the oracle builds/'
mutant "a package job that skips the release-pkg comparison" "does not run the oracles" W '/STEVEDORE_ORACLE: 1/d'
mutant "an undeclared self-pin" "no self-pin:stevedore deviation" I '/^- self-pin:stevedore:/d'
mutant "a self-pin the repackage trigger watches" "would release again" R 's|^      - components/zlib/version$|&\
      - components/stevedore/version|'
mutant "a thin pkg" "does not merge both slices" W 's/MAVERICKS_ALLOW_ARCHS: x86_64 arm64/MAVERICKS_ALLOW_ARCHS: x86_64/'
mutant "an unchecked tarball" "is not checked" W '/python3 "$SHIPYARD_SCRIPTS\/product-tar.py"/d'
mutant "\${{ }} in a run: block" 'a run: block holds' W 's/^          set -eu$/          echo "${{ github.event.head_commit.message }}"/'
mutant "an undeclared macOS job" "no macos-runner:on-target deviation" W '/^  on-target:$/,/^  publish:$/s/runs-on: ubuntu-latest/runs-on: macos-26/'
mutant "a dropped macOS deviation" "no macos-runner:package deviation" I '/^- macos-runner:package:/d'
mutant "an unwatched ingredient" "not the declared ingredients" R '/components\/clang22\/sha256/d'
mutant "a declared ingredient the trigger misses" "not the declared ingredients" I 's/^- zlib: components\/zlib\/version$/&\
- extra: components\/extra\/version/'
echo "release-workflow OK"
