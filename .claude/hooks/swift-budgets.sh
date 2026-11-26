#!/usr/bin/env bash
# PostToolUse hook: SwiftLint's size limits, the lint-lite rules
# (check-swift-lint-lite.sh) and the test-clock ratchet, on the file just edited.
#
# Both are checks check.sh --portable already runs, moved to the moment of the
# edit: a file that crosses file_length or type_body_length is cheaper to split
# while it is being written than after CI reports it 37 minutes later (#358,
# #363, #364, #368, #378, #380 each spent a run on exactly that). Unlike
# swiftlint.sh this needs no toolchain, so it works in the web sandbox, which is
# where those PRs were written.
#
# Advisory (exit 2), matching swiftlint.sh: Claude sees the message, the edit stands.
set -euo pipefail

# shellcheck source=.claude/hooks/hook-lib.sh
source "$(dirname "$0")/hook-lib.sh"

file="$(hook_file_path)"
case "$file" in
  *.swift) : ;;
  *) exit 0 ;;
esac
[ -f "$file" ] || exit 0

root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

# The size and clock checks narrow their arguments to their own scope —
# SwiftLint's lint roots, the test tree — so a file outside one is simply not
# checked there; the size check's headroom notes are left out, only its errors
# and their detail lines. The lint-lite rules scan what they're given, so they
# get only files SwiftLint lints (scripts/*.swift aren't).
findings="$(bash "$root/scripts/check-swift-size.sh" "$file" 2>&1 | grep '^error\|^ ' || true)"
case "${file#"$root"/}" in
  Sources/* | Tests/* | App/Blurt/Blurt/* | App/Blurt/BlurtUITests/* | App/BlurtiOS/*)
    lite="$(bash "$root/scripts/check-swift-lint-lite.sh" "$file" 2>/dev/null || true)"
    findings+="${lite:+${findings:+$'\n'}$lite}"
    ;;
esac
if ! clock="$(bash "$root/scripts/check-test-clock.sh" "$file" 2>&1)"; then
  findings+="${findings:+$'\n'}$clock"
fi

if [ -n "$findings" ]; then
  printf '%s\n' "$findings" >&2
  exit 2
fi
exit 0
