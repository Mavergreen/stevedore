#!/bin/sh
# platform: host-agnostic
# usage: sh tests/pins-bot-workflow-test.sh
#   .github/workflows/pins-bot.yml keeps the security shape of the family's pins bot: Renovate's branches only;
#   permissions {}; the pins job (which touches upstream's bytes) reads only and persists no credentials; the
#   push job's GITHUB_TOKEN reads only and it writes with the pins-bot App's token, contents: write alone; the
#   bot's commit is the zlib and clang22 digests and nothing else; no ${{ }} in a run: block; the run
#   the bot's own push starts cancels nothing and checks nothing. Each check is shown to refuse a mutated copy.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/pins-bot-workflow.XXXXXX")"
trap 'rm -rf "$T"' EXIT
W="$REPO/.github/workflows/pins-bot.yml"
[ -f "$W" ] || fail ".github/workflows/pins-bot.yml does not exist"
# platform: shape <workflow> prints the first invariant <workflow> breaks, and fails; nothing when it keeps them all.
shape() {
  _on="$(awk '/^on:/ { on = 1; next } on && /^[^ #]/ { exit } on && !/^ *(#.*)?$/ { print }' "$1")"
  [ "$_on" = "  push:
    branches: ['renovate/**']" ] || { echo "on: is not a push to renovate/** alone: [$_on]"; return 1; }
  grep -qx 'permissions: {}' "$1" || { echo "no permissions: {} at the top"; return 1; }
  _run="$(awk 'function ind(l) { match(l, /^ */); return RLENGTH }
    r && (/^ *$/ || ind($0) > ri) { if (index($0, "${{")) print NR ": " $0; next }
    { r = 0 }
    /^ *(- )?run:/ { ri = ind($0); r = 1; if (index($0, "${{")) print NR ": " $0 }' "$1")"
  [ -z "$_run" ] || { echo "a run: block holds \${{ }}: $_run"; return 1; }
  awk '/^  pins:$/ { j = "pins" } /^  push:$/ { j = "push" } j { print j ": " $0 }' "$1" > "$T/jobs"
  [ "$(grep -A1 '^pins:     permissions:$' "$T/jobs" | tail -1)" = 'pins:       contents: read' ] \
    || { echo "the pins job's permissions are not contents: read"; return 1; }
  if grep '^pins:' "$T/jobs" | grep -q 'write\|git push\|gh workflow'; then echo "the pins job can write"; return 1; fi
  grep -q '^pins:           persist-credentials: false\( *#.*\)\{0,1\}$' "$T/jobs" \
    || { echo "the pins job's checkout persists its credentials"; return 1; }
  grep -qx 'push:     needs: pins' "$T/jobs" || { echo "the push job does not need the pins job"; return 1; }
  [ "$(grep -A1 '^push:     permissions:$' "$T/jobs" | tail -1)" = 'push:       contents: read' ] \
    && ! grep '^push:' "$T/jobs" | grep -Eq '^push:       (contents|actions): write$' \
    || { echo "the push job's GITHUB_TOKEN does not read only"; return 1; }
  grep -qx 'push:         uses: actions/create-github-app-token@v3' "$T/jobs" \
    && grep -qx 'push:           client-id: ${{ vars.PINS_BOT_CLIENT_ID }}' "$T/jobs" \
    && grep -qx 'push:           private-key: ${{ secrets.PINS_BOT_PRIVATE_KEY }}' "$T/jobs" \
    && [ "$(grep -c '^push: *permission-' "$T/jobs")" = 1 ] && grep -qx 'push:           permission-contents: write' "$T/jobs" \
    || { echo "the push job does not mint the pins-bot App's token for contents: write alone"; return 1; }
  grep -qx 'push:           token: ${{ steps.app.outputs.token }}' "$T/jobs" \
    || { echo "the push job's checkout does not hold the App's token"; return 1; }
  if grep -q 'gh workflow run\|GH_TOKEN\|github.token' "$1"; then echo "the workflow dispatches a run or uses GITHUB_TOKEN to write"; return 1; fi
  grep -qF "user.email='342268518+mavergreen-pins-bot[bot]@users.noreply.github.com'" "$1" \
    || { echo "the commit is not the pins-bot App's bot's"; return 1; }
  grep -qxF "  group: pins-bot-\${{ github.ref }}\${{ github.actor == 'mavergreen-pins-bot[bot]' && format('-{0}', github.run_id) || '' }}" "$1" \
    && grep -qxF "pins:     if: github.actor != 'mavergreen-pins-bot[bot]'" "$T/jobs" \
    || { echo "the run the bot's own push starts can cancel the run that pushed, or checks again"; return 1; }
  grep -qF "commit -q -m \"chore(pins): verified zlib and Linux compiler digests\"" "$1" \
    || { echo "the commit message is not chore(pins): verified zlib and Linux compiler digests"; return 1; }
  [ "$(grep -c '^ *git add components/zlib/sha256 components/clang22/sha256$' "$1")" = 1 ] \
    && [ "$(grep -c '^ *components/zlib/sha256 components/clang22/sha256$' "$1")" = 1 ] \
    && [ "$(grep -c 'components/' "$1")" = 2 ] \
    || { echo "the committed paths are not components/zlib/sha256 and components/clang22/sha256 alone"; return 1; }
}
shape "$W" > "$T/out" || fail "pins-bot.yml: $(cat "$T/out")"
mutant() {  # mutant <what it breaks> <expected message> <sed script> -- shape must refuse the mutated workflow
  sed "$3" "$W" > "$T/mutant.yml"
  if cmp -s "$W" "$T/mutant.yml"; then fail "mutant '$1' changed nothing"; fi
  if shape "$T/mutant.yml" > "$T/out"; then fail "shape passed a workflow with $1"; fi
  grep -qF "$2" "$T/out" || fail "shape, $1: said [$(cat "$T/out")]"
  echo "   refused: $1"
}
mutant "a pull_request_target trigger" "on: is not a push" 's/^  push:$/  pull_request_target:\
  push:/'
mutant "another branch" "on: is not a push" "s|'renovate/\*\*'|'**'|"
mutant "a default permission" "no permissions: {}" 's/^permissions: {}$/permissions: read-all/'
mutant "\${{ }} in a run: block" 'a run: block holds' 's/^          set -eu$/          echo "${{ github.event.head_commit.message }}"/'
mutant "a writing pins job" "the pins job's permissions" '/^  pins:$/,/^  push:$/s/contents: read/contents: write/'
mutant "the pins job keeping its credentials" "persists its credentials" 's/persist-credentials: false/persist-credentials: true/'
mutant "a push job that needs nothing" "does not need the pins job" '/^    needs: pins$/d'
mutant "a writing push job GITHUB_TOKEN" "does not read only" '/^    needs: pins$/,/^@@never@@/s/^      contents: read$/      contents: write/'
mutant "an extra actions: write on the push job" "does not read only" '/^    needs: pins$/,/^@@never@@/s/^      contents: read$/&\
      actions: write/'
mutant "the App token with a broader permission" "contents: write alone" 's/^          permission-contents: write$/&\
          permission-issues: write/'
mutant "the App token as GITHUB_TOKEN" "does not hold the App's token" 's/token: ${{ steps.app.outputs.token }}/token: ${{ github.token }}/'
mutant "a different App client id" "does not mint" 's/vars.PINS_BOT_CLIENT_ID/vars.OTHER/'
mutant "a different App key" "does not mint" 's/secrets.PINS_BOT_PRIVATE_KEY/secrets.OTHER/'
mutant "a dispatch" "dispatches a run" 's/^          git push origin.*/&\
          gh workflow run release.yml/'
mutant "another committer" "not the pins-bot App's bot's" 's/342268518+mavergreen-pins-bot/1+someone/'
mutant "a changed concurrency group" "can cancel the run that pushed" "s/ && format('-{0}', github.run_id) || ''//"
mutant "the pins job running on the bot's own push" "can cancel the run that pushed" "/^    if: github.actor != 'mavergreen-pins-bot\[bot\]'\$/d"
mutant "another commit message" "the commit message" "s/verified zlib and Linux compiler digests/the tarball/"
mutant "another committed path" "the committed paths" 's|components/clang22/sha256$|components/clang22/version|'
mutant "an extra committed path" "the committed paths" 's|^          git add components/zlib/sha256 components/clang22/sha256$|& UPSTREAM_VERSION components/x|'
echo "pins-bot-workflow OK"
