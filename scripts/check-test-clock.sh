#!/bin/bash
# Tests that wait on real time must say why.
#
# A test that sleeps a fixed interval, or hands production code a real clock and
# then waits for its timer, passes on a Mac and fails on a loaded CI runner or
# under the address sanitizer, where the main actor can stall for seconds. Those
# flakes cost more CI runs than anything but SwiftLint's size limits — #353,
# #357, #370, #372, #379, #380, #393, #396, #399, #400, #401 — and they mostly
# failed *other* PRs: #379 changed only docs and failed ios-sanitizers.
#
# The fix each time was the same: step a TestClock (waitUntilSleeping, then
# advance) or wait for the event itself (waitUntil / until, whose 30 s bound only
# catches a hang), never a duration. Some waits are legitimate — a fake that
# hangs until cancelled, the poll inside waitUntil, a UI test, a live-device
# suite, a check that something did NOT happen (a slow runner can only make
# those pass) — so each one says why with `// wall-clock-ok: <reason>`, at the
# end of its line or on the line above, and an unmarked one fails.
#
# Usage: check-test-clock.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PATTERN='Task\.sleep\(|Thread\.sleep|usleep\(|ContinuousClock\(\)|SuspendingClock\(\)'
SCOPE=(
  'Tests/*.swift'
  'App/Blurt/BlurtUITests/*.swift'
  'App/BlurtiOS/BlurtiOSTests/*.swift'
  'App/BlurtiOS/BlurtiOSUITests/*.swift'
)

# Every wall-clock wait not marked ok, as "path:line:text". A marker on the line
# itself or on a comment line just above it counts: a trailing comment would push
# many of these lines past swift-format's 120 columns.
waits() {
  local files
  files="$(git ls-files -- "${SCOPE[@]}")"
  [ -n "$files" ] || {
    echo "error: the test scope matches no tracked files: ${SCOPE[*]}" >&2
    exit 1
  }
  # The pattern goes in through the environment: `awk -v` would process its
  # backslashes, turning `\.` into "any character" on one awk and not another.
  # shellcheck disable=SC2086 # one path per line, no spaces in this tree
  PAT="$PATTERN" awk '
    BEGIN { pat = ENVIRON["PAT"] }
    FNR == 1 { prev = "" }
    {
      line = $0
      if (line ~ pat && line !~ /wall-clock-ok:/ && prev !~ /wall-clock-ok:/ \
        && line !~ /^[[:space:]]*(\/\/|\*|\/\*)/) {
        print FILENAME ":" FNR ":" line
      }
      prev = line
    }
  ' $files
}

hits="$(waits)"
if [ -n "$hits" ]; then
  echo "error: tests wait on the wall clock without saying why:" >&2
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  echo "       A fixed wait passes on a Mac and fails on a loaded runner or under ASan." >&2
  echo "       Step a TestClock (waitUntilSleeping, then advance) or wait for the event" >&2
  echo "       (waitUntil / until). If real time is genuinely the point, mark it with" >&2
  echo "       '// wall-clock-ok: <reason>' at the end of the line or on the line above." >&2
  exit 1
fi
echo "every wall-clock wait in the tests says why"
