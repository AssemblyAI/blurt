#!/usr/bin/env bash
# PreToolUse hook: block hand-edits to the XcodeGen-generated Xcode project.
#
# `App/Blurt/Blurt.xcodeproj/project.pbxproj` is generated from
# `App/Blurt/project.yml`; check.sh fails if `xcodegen generate` would change
# the committed file, so any manual edit breaks CI. Edit project.yml and run
# `xcodegen generate` instead.
#
# Reads the hook payload (JSON) on stdin. Exit 2 blocks the tool call and feeds
# the stderr message back to Claude; exit 0 allows everything else.
set -euo pipefail

# shellcheck source=.claude/hooks/hook-lib.sh
source "$(dirname "$0")/hook-lib.sh"

file="$(hook_file_path)"

case "$file" in
  */Blurt.xcodeproj/project.pbxproj)
    echo "Refusing to edit the generated project.pbxproj. Edit App/Blurt/project.yml and run 'xcodegen generate' — check.sh fails on pbxproj drift." >&2
    exit 2
    ;;
esac

exit 0
