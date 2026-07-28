#!/usr/bin/env bash
# Shared helpers for this repo's Claude Code hooks. Sourced, never executed, and
# side-effect-free at source time — each hook still owns its own `set -euo
# pipefail` and its own exit policy.

# Echo the `tool_input.file_path` from the hook payload on stdin, or nothing when
# the payload has no file path (a non-file tool) or can't be parsed. The one
# definition of the payload contract: all three hooks read the same field, and a
# copy in each meant a change to the shape — or a python3 fallback — was three
# edits, with a hook that silently resolved an empty path just no-opping.
hook_file_path() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' \
    2>/dev/null || true
}
