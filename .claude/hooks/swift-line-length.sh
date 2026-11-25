#!/usr/bin/env bash
# PostToolUse hook: flag over-long lines in an edited Swift file.
#
# Why this exists alongside swift-format.sh: that hook (and swiftlint.sh) is a
# silent no-op off-Mac, because swift-format and SwiftLint ship their Linux builds
# as GitHub release binaries the default network policy blocks — so in a web/Linux
# sandbox *nothing* checks Swift style until CI. Line width is the one
# `swift-format` rule that needs no toolchain at all, so it's worth checking here:
# it's also the rule an agent writing long doc comments trips most.
#
# Deliberately narrow. This is NOT a swift-format substitute: indentation,
# wrapping, and every other rule still need the real tool, which is why this stays
# quiet when swift-format is available and about to reformat the file anyway.
# `swift-format lint --strict` on CI remains the authority.
#
# Advisory (exit 2) rather than blocking, matching swiftlint.sh.
set -euo pipefail

# shellcheck source=.claude/hooks/hook-lib.sh
source "$(dirname "$0")/hook-lib.sh"

file="$(hook_file_path)"

case "$file" in
  *.swift) : ;;
  *) exit 0 ;;
esac
[ -f "$file" ] || exit 0

# swift-format present (macOS, or a Linux build on PATH) means swift-format.sh just
# reflowed this file and owns the verdict — don't second-guess it.
if command -v xcrun >/dev/null 2>&1 || command -v swift-format >/dev/null 2>&1; then
  exit 0
fi

# The limit is .swift-format's `lineLength`, read from the config so the two can't
# drift; 120 is the fallback if the config is missing or unparseable.
config="${CLAUDE_PROJECT_DIR:-.}/.swift-format"
limit=120
if [ -f "$config" ]; then
  parsed="$(
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("lineLength",""))' \
      "$config" 2>/dev/null || true
  )"
  case "$parsed" in
    '' | *[!0-9]*) : ;;
    *) limit="$parsed" ;;
  esac
fi

# Report every offender with its width, so the fix doesn't need a second pass to
# find them. Counted in characters, as swift-format counts columns — not awk's
# `length`, which is bytes in mawk and macOS's awk: the sources' em dashes are
# three bytes each, so a comment exactly at the limit read as 124 columns.
findings="$(
  python3 -c '
import sys
limit = int(sys.argv[1])
with open(sys.argv[2], encoding="utf-8", errors="replace") as source:
    for number, line in enumerate(source, 1):
        width = len(line.rstrip("\r\n"))
        if width > limit:
            print(f"  {number}: {width} columns")
' "$limit" "$file"
)"

if [ -n "$findings" ]; then
  {
    echo "Lines over $limit columns in $file (swift-format lint --strict fails CI on these):"
    printf '%s\n' "$findings"
    echo "  Reflow them — swift-format isn't installed here, so CI is the only other check."
  } >&2
  exit 2
fi

exit 0
