#!/usr/bin/env bash
# PreToolUse hook: run `scripts/check.sh --portable` before a `git push`, and
# block the push when it fails.
#
# CLAUDE.md's first rule for a fast green is "run check.sh --portable before every
# push", and the PRs that broke it are the ones that needed another ~37-minute CI
# run for something it would have named in ~20 s: jscpd clones (#384, #392, #420,
# #422), the size budgets after merging main into a branch (#363, #378 — a merge
# fires no edit hook), and the lint-lite rules (#414, #422, #425). A rule an agent
# has to remember is skipped exactly when it is in a hurry; this makes it the push.
#
# Exit 2 blocks the Bash call and hands Claude the failing checks. To push anyway
# (a docs-only fix-up while an unrelated check is red on main, say), prefix the
# command with BLURT_SKIP_PUSH_GATE=1 and say why in the PR.
set -euo pipefail

# shellcheck source=.claude/hooks/hook-lib.sh
source "$(dirname "$0")/hook-lib.sh"

cmd="$(hook_command)"
# `git push` anywhere in the command line, including after `&&` or `;`.
# `git`, then any options (`-C dir`), then `push`, all within one command of the line.
grep -qE '(^|[^[:alnum:]_./-])git[[:space:]]([^;&|]*[[:space:]])?push([[:space:]]|$)' <<<"$cmd" || exit 0
case "$cmd" in
  *BLURT_SKIP_PUSH_GATE=1*) exit 0 ;;
esac

root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
log="$(mktemp "${TMPDIR:-/tmp}/push-gate.XXXXXX")"
if (cd "$root" && scripts/check.sh --portable) >"$log" 2>&1; then
  rm -f "$log"
  exit 0
fi

{
  echo "push blocked: scripts/check.sh --portable failed (full log: $log)."
  echo "Fix every failure below in one commit, then push again — each push restarts CI's ~37-minute run."
  echo "---"
  # The failures with their messages, then check.sh's closing summary.
  grep -E '^(error|FAIL|  FAIL|==> FAILED|  - |✗)|: (modifier_order|no_empty_block|NoBlockComments|catch-where): |Clone found|over SwiftLint' "$log" | head -40 || true
  echo "---"
  tail -15 "$log"
} >&2
exit 2
