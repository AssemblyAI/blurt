#!/usr/bin/env bash
# PostToolUse hook: format an edited Swift file with swift-format — the repo's
# formatting authority (check.sh runs `swift-format lint --strict`). Running it
# on every edit keeps changes CI-clean by construction.
#
# Reads the hook payload (JSON) on stdin; formats only *.swift files. Always
# exits 0 so a formatting hiccup never blocks the edit.
set -euo pipefail

# shellcheck source=.claude/hooks/hook-lib.sh
source "$(dirname "$0")/hook-lib.sh"

file="$(hook_file_path)"

case "$file" in
  *.swift)
    config="${CLAUDE_PROJECT_DIR:-.}/.swift-format"
    # The same swift-format check.sh lints with: the Xcode toolchain's, else a
    # bare one on PATH (a Linux build in a web sandbox). Absent both, silently
    # skip — CI's `swift-format lint --strict` remains the authority.
    # shellcheck source=scripts/swift-format-lib.sh
    source "$(dirname "$0")/../../scripts/swift-format-lib.sh"
    [ "${#SWIFT_FORMAT[@]}" -gt 0 ] || exit 0
    if [ -f "$file" ]; then
      if [ -f "$config" ]; then
        "${SWIFT_FORMAT[@]}" format -i --configuration "$config" "$file" >/dev/null 2>&1 || true
      else
        "${SWIFT_FORMAT[@]}" format -i "$file" >/dev/null 2>&1 || true
      fi
    fi
    ;;
esac

exit 0
