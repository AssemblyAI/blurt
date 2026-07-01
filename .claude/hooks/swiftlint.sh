#!/usr/bin/env bash
# PostToolUse hook: lint an edited Swift file with SwiftLint — the repo's
# *correctness* authority (check.sh runs `swiftlint lint --strict`, where any
# violation, warning included, fails CI). swift-format.sh already keeps the file
# formatted; this catches the smells/complexity limits swift-format can't, so a
# lint failure surfaces at edit time instead of in CI.
#
# Reads the hook payload (JSON) on stdin; lints only *.swift files against the
# repo's .swiftlint.yml. Advisory — findings go back to Claude (exit 2) rather
# than hard-blocking the edit, matching copy-lint.sh. Skipped if swiftlint is
# absent (same as check.sh).
set -euo pipefail

payload="$(cat)"
file="$(printf '%s' "$payload" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' \
  2>/dev/null || true)"

case "$file" in
  *.swift) : ;;
  *) exit 0 ;;
esac
[ -f "$file" ] || exit 0
command -v swiftlint >/dev/null 2>&1 || exit 0

cd "${CLAUDE_PROJECT_DIR:-.}"

# --strict mirrors check.sh: warnings count as violations. --quiet drops the
# progress banner so only findings reach stderr.
findings="$(swiftlint lint --strict --quiet -- "$file" 2>/dev/null || true)"

if [ -n "$findings" ]; then
  {
    echo "SwiftLint flagged $file (check.sh runs --strict, so these fail CI):"
    printf '%s\n' "$findings" | sed 's/^/  /'
    echo "  (Fix before claiming green — warnings are failures under --strict.)"
  } >&2
  exit 2
fi

exit 0
