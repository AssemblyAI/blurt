#!/usr/bin/env bash
# PostToolUse hook: format an edited Swift file with swift-format — the repo's
# formatting authority (check.sh runs `swift-format lint --strict`). Running it
# on every edit keeps changes CI-clean by construction.
#
# Reads the hook payload (JSON) on stdin; formats only *.swift files. Always
# exits 0 so a formatting hiccup never blocks the edit.
set -euo pipefail

payload="$(cat)"
file="$(printf '%s' "$payload" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' \
  2>/dev/null || true)"

case "$file" in
  *.swift)
    config="${CLAUDE_PROJECT_DIR:-.}/.swift-format"
    if command -v xcrun >/dev/null 2>&1 && [ -f "$file" ]; then
      if [ -f "$config" ]; then
        xcrun swift-format format -i --configuration "$config" "$file" >/dev/null 2>&1 || true
      else
        xcrun swift-format format -i "$file" >/dev/null 2>&1 || true
      fi
    fi
    ;;
esac

exit 0
