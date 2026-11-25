#!/bin/bash
# A ratchet on tests that wait on real time.
#
# A test that sleeps a fixed interval, or hands production code a real clock and
# then waits for its timer, passes on a Mac and fails on a loaded CI runner or
# under the address sanitizer, where the main actor can stall for seconds. Those
# flakes cost more CI runs than anything but SwiftLint's size limits — #353,
# #357, #370, #372, #379, #380, #393, #396, #399, #400, #401 — and they mostly
# failed *other* PRs: #379 changed only docs and failed ios-sanitizers.
#
# The fix each time was the same: step a TestClock (waitUntilSleeping, then
# advance) or wait for the event itself (waitUntil / until), never a duration.
# Many existing waits are legitimate — a fake that hangs until cancelled, the
# poll inside waitUntil, a UI test settling an animation — so this is a ratchet,
# not a ban: test-clock-baseline.txt records how many each file has, and a file
# may not gain one. A new wait that is genuinely needed takes a trailing
# `// wall-clock-ok: <reason>` comment instead.
#
# Usage:
#   check-test-clock.sh            fail if any file has more waits than its baseline
#   check-test-clock.sh --update   rewrite the baseline from the tree (after removing waits)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BASELINE="scripts/test-clock-baseline.txt"
PATTERN='Task\.sleep\(|Thread\.sleep|usleep\(|ContinuousClock\(\)|SuspendingClock\(\)'
SCOPE=(
  'Tests/*.swift'
  'App/Blurt/BlurtUITests/*.swift'
  'App/BlurtiOS/BlurtiOSTests/*.swift'
  'App/BlurtiOS/BlurtiOSUITests/*.swift'
)

# "count path" per file with at least one wall-clock wait, sorted by path.
current() {
  local files
  files="$(git ls-files -- "${SCOPE[@]}")"
  [ -n "$files" ] || {
    echo "error: the test scope matches no tracked files: ${SCOPE[*]}" >&2
    exit 1
  }
  # shellcheck disable=SC2086 # one path per line, no spaces in this tree
  { grep -nE "$PATTERN" $files || true; } | awk '
    { body = $0; sub(/^[^:]*:[0-9]+:/, "", body) }
    body ~ /wall-clock-ok:/ { next }
    body ~ /^[[:space:]]*(\/\/|\*|\/\*)/ { next }
    { split($0, f, ":"); n[f[1]]++ }
    END { for (p in n) printf "%d %s\n", n[p], p }
  ' | sort -k2
}

if [ "${1:-}" = "--update" ]; then
  current >"$BASELINE"
  echo "wrote $BASELINE ($(wc -l <"$BASELINE" | tr -d ' ') files)"
  exit 0
fi

[ -f "$BASELINE" ] || {
  echo "error: $BASELINE is missing; run scripts/check-test-clock.sh --update" >&2
  exit 1
}

grew=0
shrank=0
while read -r count path; do
  allowed="$(awk -v p="$path" '$2 == p { print $1 }' "$BASELINE")"
  allowed="${allowed:-0}"
  if [ "$count" -gt "$allowed" ]; then
    echo "error: $path waits on the wall clock $count times (baseline $allowed):" >&2
    grep -nE "$PATTERN" "$path" | grep -v 'wall-clock-ok:' | sed 's/^/  /' >&2
    grew=1
  elif [ "$count" -lt "$allowed" ]; then
    shrank=1
  fi
done < <(current)

# A file whose waits were all removed drops out of `current`; catch that too.
while read -r _ path; do
  current | awk -v p="$path" '$2 == p { found = 1 } END { exit !found }' || shrank=1
done <"$BASELINE"

if [ "$grew" -ne 0 ]; then
  echo "       A fixed wait passes on a Mac and fails on a loaded runner or under ASan." >&2
  echo "       Step a TestClock (waitUntilSleeping, then advance) or wait for the event" >&2
  echo "       (waitUntil / until). If real time is genuinely the point, end the line" >&2
  echo "       with '// wall-clock-ok: <reason>'." >&2
  exit 1
fi
if [ "$shrank" -ne 0 ]; then
  echo "error: fewer wall-clock waits than $BASELINE records — good; lock it in with" >&2
  echo "       scripts/check-test-clock.sh --update and commit the baseline." >&2
  exit 1
fi
echo "no test gained a wall-clock wait ($(wc -l <"$BASELINE" | tr -d ' ') files at baseline)"
