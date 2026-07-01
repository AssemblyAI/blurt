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
    # Prefer xcrun (macOS); fall back to a bare swift-format on PATH so a Linux
    # build (e.g. in a web sandbox) formats too. Absent both, silently skip —
    # CI's `swift-format lint --strict` remains the authority.
    if command -v xcrun >/dev/null 2>&1; then
      swift_format=(xcrun swift-format)
    elif command -v swift-format >/dev/null 2>&1; then
      swift_format=(swift-format)
    else
      exit 0
    fi
    if [ -f "$file" ]; then
      if [ -f "$config" ]; then
        "${swift_format[@]}" format -i --configuration "$config" "$file" >/dev/null 2>&1 || true
      else
        "${swift_format[@]}" format -i "$file" >/dev/null 2>&1 || true
      fi
    fi
    ;;
esac

exit 0
