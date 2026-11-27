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
# Usage:
#   check-test-clock.sh               every tracked test file
#   check-test-clock.sh FILE...       just these, less any outside the test
#                                     scope (the PostToolUse hook's mode)
#   check-test-clock.sh --self-test   the scan against known inputs

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# A bare `sleep(` counts as well as `usleep(`, but not a method of that name
# (`clock.sleep(`, `Task.sleep(` has its own entry) or a declaration of one: a
# test clock's `func sleep(until:)` is the thing that replaces the wait.
PATTERN='Task\.sleep\(|Thread\.sleep|usleep\(|(^|[^[:alnum:]_.])sleep\(|ContinuousClock\(\)|SuspendingClock\(\)'
DECLARATION='func[[:space:]]+sleep\('
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
  # Only the listed files still on disk: one deleted without `git rm` stays in the
  # index, and awk aborts on the first file it cannot open.
  local f present=()
  while IFS= read -r f; do
    if [ -f "$f" ]; then present+=("$f"); fi
  done <<<"$files"
  [ "${#present[@]}" -gt 0 ] || return 0
  unmarked "${present[@]}"
}

# The wall-clock waits in FILE... not marked ok, as "path:line:text".
#
# The line above vouches for a wait only when it is a comment line carrying the
# marker. A marked *wait* on the line above is no reason for this one: two sleeps
# in a row, the first marked at its end, used to pass the second unmarked.
unmarked() {
  # The pattern goes in through the environment: `awk -v` would process its
  # backslashes, turning `\.` into "any character" on one awk and not another.
  PAT="$PATTERN" DECL="$DECLARATION" awk '
    BEGIN { pat = ENVIRON["PAT"]; decl = ENVIRON["DECL"] }
    FNR == 1 { above = 0 }
    {
      line = $0
      comment = (line ~ /^[[:space:]]*(\/\/|\*|\/\*)/)
      if (line ~ pat && line !~ decl && line !~ /wall-clock-ok:/ && !above && !comment) {
        print FILENAME ":" FNR ":" line
      }
      above = (comment && line ~ /wall-clock-ok:/)
    }
  ' "$@"
}

self_test() {
  local dir failed=0 got want
  dir="$(mktemp -d "${TMPDIR:-/tmp}/test-clock.XXXXXX")"
  # shellcheck disable=SC2064 # expand now: $dir is local
  trap "rm -rf '$dir'" RETURN
  cat >"$dir/Waits.swift" <<'SWIFT'
try await Task.sleep(for: .seconds(1))  // wall-clock-ok: marked at its end
// wall-clock-ok: marked on the comment line above
try await Task.sleep(for: .seconds(2))
try await Task.sleep(for: .seconds(3))  // wall-clock-ok: marks only itself
try await Task.sleep(for: .seconds(4))
// try await Task.sleep(for: .seconds(5))
let clock = ContinuousClock()
sleep(1)
usleep(100_000)
try await clock.sleep(for: .seconds(1))
func sleep(until deadline: Instant, tolerance _: Duration?) async throws {
SWIFT
  got="$(unmarked "$dir/Waits.swift" | cut -d: -f2)"
  want="$(printf '%s\n' 5 7 8 9)"
  if [ "$got" = "$want" ]; then
    echo "  ok   flags unmarked waits, bare sleep( included; a marker covers its own line or the one below a comment"
  else
    echo "  FAIL flagged lines '$(echo "$got" | tr '\n' ' ')', expected '$(echo "$want" | tr '\n' ' ')'" >&2
    failed=1
  fi
  return "$failed"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

if [ "$#" -gt 0 ]; then
  # Just these files, tracked or not — the PostToolUse hook's mode. The tracked
  # list alone missed exactly the file the hook fires on most: a test suite just
  # written, which git doesn't list until it is staged. Any outside the test
  # scope are dropped; a pathspec's `*` crosses `/`, and so does a `[[ == ]]`
  # pattern's.
  in_scope=()
  for f in "$@"; do
    for pat in "${SCOPE[@]}"; do
      # shellcheck disable=SC2053 # $pat is a glob on purpose
      if [[ ${f#"$REPO_ROOT"/} == $pat ]]; then
        in_scope+=("$f")
        break
      fi
    done
  done
  [ "${#in_scope[@]}" -gt 0 ] || exit 0
  hits="$(unmarked "${in_scope[@]}")"
else
  hits="$(waits)"
fi
if [ -n "$hits" ]; then
  echo "error: tests wait on the wall clock without saying why:" >&2
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  echo "       A fixed wait passes on a Mac and fails on a loaded runner or under ASan." >&2
  echo "       Step a TestClock (waitUntilSleeping, then advance) or wait for the event" >&2
  echo "       (waitUntil / until). If real time is genuinely the point, mark it with" >&2
  echo "       '// wall-clock-ok: <reason>' at the end of the line or on the line above." >&2
  exit 1
fi
[ "$#" -gt 0 ] || echo "every wall-clock wait in the tests says why"
