#!/bin/bash
# Flag GNU-only shell idioms in scripts/ and .claude/hooks/.
#
# These scripts run in two places with different userlands: a developer's Mac and
# CI (macos-26) get BSD coreutils, while a Linux / web sandbox gets GNU. An idiom
# that only exists in GNU therefore works everywhere the change is written and
# fails everywhere it ships. PR #116 paid for exactly that — "Fix the sitemap
# <loc> strip on BSD sed (macOS CI)" — and shellcheck does not look for it,
# because nothing here is wrong as shell, only wrong as *portable* shell.
#
# Scope is deliberately scripts/ and .claude/hooks/ only. Workflow `run:` blocks
# are excluded: several jobs run on ubuntu-latest, where GNU is the correct
# assumption, so gating them would flag working code.
#
# Escape hatch: end the line with `# portable-ok: <reason>` when a flagged idiom
# is genuinely portable or genuinely intended. Lines that are entirely a comment
# are skipped, so prose *about* an idiom (release.test.sh discusses `sort -V`)
# doesn't trip the gate.
#
# Not exhaustive, and not trying to be — it carries the divergences that have bitten
# this repo or are one typo away from doing so. Add to the table as they turn up.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Two parallel arrays rather than one "pattern|advice" list, because the patterns
# themselves contain `|` (regex alternation) — splitting on the first one truncates
# the pattern mid-expression, and a truncated regex is a rule that silently never
# matches. Kept honest by the self-test at the bottom of this file.
#
# `sed -i` is the subtle entry: GNU treats the backup suffix as optional, BSD
# requires it, so bare `sed -i` edits in place on Linux and eats the next argument
# as the suffix on macOS. The pattern therefore matches -i only when nothing
# follows it, leaving the portable `sed -i.bak` form alone.
PATTERNS=(
  "sed[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-i([[:space:]]|$)"
  "sed[[:space:]]+-[a-zA-Z]*r[[:space:]]"
  "grep[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*(-[a-zA-Z]*P|--perl-regexp)"
  "readlink[[:space:]]+-f"
  "stat[[:space:]]+-c"
  "date[[:space:]]+(-d[[:space:]]|--date)"
  "base64[[:space:]]+-w"
  "xargs[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-r"
  "find[[:space:]]+.*-printf"
  "(^|[[:space:]])timeout[[:space:]]"
  "(^|[[:space:]])(md5sum|sha[0-9]+sum)([[:space:]]|$)"
  "(^|[[:space:]])tac([[:space:]]|$)"
)
ADVICE=(
  "sed -i.bak (then rm), or a temp file"
  "sed -E (BSD has no -r)"
  "grep -E, or awk"
  "cd \"\$(dirname …)\" && pwd"
  "stat -f (BSD) — or avoid stat"
  "date -j -f (BSD) — or avoid date arithmetic"
  "base64 | tr -d '\\n'"
  "guard on an empty input instead (BSD xargs has no -r)"
  "find -exec, or -print piped through sed"
  "not on macOS by default — restructure, or gate on command -v"
  "shasum -a 256 (present in both userlands)"
  "tail -r (BSD) — or sed '1!G;h;\$!d'"
)

[ "${#PATTERNS[@]}" -eq "${#ADVICE[@]}" ] || {
  echo "error: PATTERNS and ADVICE are different lengths — a rule lost its advice" >&2
  exit 1
}

# One known-bad line per rule, same order. `--self-test` asserts each pattern
# matches its own probe, which is the property the first draft of this file
# quietly lost: a rule that matches nothing looks identical to a clean tree.
PROBES=(
  "sed -i 's/a/b/' f"
  "sed -r 's/(a)/\\1/' f"
  "grep -P '\\\\d' f"
  "readlink -f ./x"
  "stat -c '%s' f"
  "date -d '1 day ago'"
  "base64 -w0 f"
  "printf 'x' | xargs -r echo"
  "find . -printf '%p'"
  "timeout 5 sleep 1"
  "md5sum f"
  "tac f"
)

if [ "${1:-}" = "--self-test" ]; then
  failed=0
  for i in "${!PATTERNS[@]}"; do
    if printf '%s\n' "${PROBES[$i]}" | grep -qE "${PATTERNS[$i]}"; then
      echo "  ok   rule $i flags: ${PROBES[$i]}"
    else
      echo "  FAIL rule $i does not match its own probe: ${PROBES[$i]}" >&2
      failed=1
    fi
  done
  # The negatives matter as much: a gate that flags the portable form is a gate
  # people route around. `sed -i.bak` is what release-bump.sh actually uses.
  for good in "sed -i.bak 's/a/b/' f" "sed -E 's/(a)/x/' f" "grep -E 'x' f"; do
    if printf '%s\n' "$good" | grep -qE "${PATTERNS[0]}|${PATTERNS[1]}|${PATTERNS[2]}"; then
      echo "  FAIL portable form flagged: $good" >&2
      failed=1
    else
      echo "  ok   portable form allowed: $good"
    fi
  done
  [ "$failed" -eq 0 ] || exit 1
  echo "check-portability.sh: all ${#PATTERNS[@]} rules live"
  exit 0
fi

FILES=$(git ls-files 'scripts/*.sh' '.claude/hooks/*.sh')
[ -n "$FILES" ] || {
  echo "error: no shell scripts matched — the file list broke" >&2
  exit 1
}

VIOLATION=0
for i in "${!PATTERNS[@]}"; do
  pattern=${PATTERNS[$i]}
  advice=${ADVICE[$i]}
  # grep exits 1 on "no match" (the good case) and 2+ on a bad pattern. Those are
  # distinguished on purpose: `|| true` over both would turn a broken regex into a
  # rule that passes everything, which is how the first draft of this file shipped
  # eight silently-dead rules.
  status=0
  # shellcheck disable=SC2086
  hits=$(grep -nE "$pattern" $FILES) || status=$?
  if [ "$status" -gt 1 ]; then
    echo "error: rule $i is not a valid regex (grep exit $status): $pattern" >&2
    exit 1
  fi
  [ -n "$hits" ] || continue
  # Drop whole-line comments and anything the author marked portable-ok. The
  # filename:lineno: prefix is stripped for the test, not for the report.
  hits=$(printf '%s\n' "$hits" | awk -F: '
    { body = substr($0, index($0, $3)) }
    body ~ /portable-ok:/ { next }
    body ~ /^[[:space:]]*#/ { next }
    { print }
  ')
  [ -n "$hits" ] || continue
  echo "error: GNU-only idiom — use ${advice}:" >&2
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  VIOLATION=1
done

[ "$VIOLATION" -eq 0 ] || {
  echo "       These scripts run on BSD userland (macOS, and CI on macos-26) as well as" >&2
  echo "       GNU (Linux / web sandbox). Mark a false positive with a trailing" >&2
  echo "       '# portable-ok: <reason>' comment." >&2
  exit 1
}

echo "$(printf '%s\n' "$FILES" | wc -l | tr -d ' ') shell scripts carry no GNU-only idioms"
