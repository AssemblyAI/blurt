#!/usr/bin/env bash
# PostToolUse hook: SwiftLint's size limits and the test-clock ratchet, on the
# file just edited.
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
rel="${file#"$root"/}"

findings=""
# Only the files SwiftLint lints (scripts/*.swift aren't).
case "$rel" in
  Sources/* | Tests/* | App/Blurt/Blurt/* | App/Blurt/BlurtUITests/* | App/BlurtiOS/*)
    findings+="$(bash "$root/scripts/check-swift-size.sh" "$file" 2>&1 | grep '^error\|^ ' || true)"
    ;;
esac
case "$rel" in
  Tests/* | App/Blurt/BlurtUITests/* | App/BlurtiOS/BlurtiOSTests/* | App/BlurtiOS/BlurtiOSUITests/*)
    clock="$(bash "$root/scripts/check-test-clock.sh" 2>&1 || true)"
    # Report only a gain in this file; a shrink is good news for check.sh to lock in.
    if grep -q "^error: $rel waits on the wall clock" <<<"$clock"; then
      findings+="${findings:+$'\n'}$(sed -n "/^error: ${rel//\//\\/} waits/,/wall-clock-ok/p" <<<"$clock")"
    fi
    ;;
esac

if [ -n "$findings" ]; then
  printf '%s\n' "$findings" >&2
  exit 2
fi
exit 0
