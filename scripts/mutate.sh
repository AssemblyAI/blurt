#!/bin/bash
# Mutation testing for the engine's pure-logic files: change one operator in the
# source, re-run the suite, and record whether any test noticed.
#
# Why this exists, given `check.sh` already gates line coverage: coverage answers
# "did this line run?", which the engine is now near the ceiling of (~89%, and the
# rest is Accessibility/TCC/CGEvent code no CI process can exercise). The question
# it cannot answer is "is this line *asserted*?" — a line can execute, and its
# value be wrong, and every test still pass. A surviving mutant is exactly that: a
# behaviour change no test objected to.
#
# So the default target list below is deliberately the files already at or near
# 100% line coverage. Those are the ones where the coverage number has nothing
# left to say, and where a survivor is a real finding rather than a restatement of
# "nothing covers this file."
#
# Deliberately NOT part of `check.sh`. A full run is minutes, not seconds, and
# survivors need judgement (some are equivalent mutants — a change that genuinely
# cannot alter behaviour, which no test can be expected to catch). A required gate
# that reports unactionable failures is a gate people learn to skip. Run this by
# hand, and treat survivors as a to-do list.
#
# Usage:
#   scripts/mutate.sh                       # all mutants in the default target set
#   scripts/mutate.sh --max 40              # stop after 40 mutants
#   scripts/mutate.sh --files "a.swift b.swift"
#   scripts/mutate.sh --list                # enumerate mutants, run nothing
#
# A line ending `// mutate-ok: <reason>` is exempt — for equivalent mutants only
# (a change that provably cannot alter behaviour), matching check-portability.sh.
#
# Safety: this edits tracked source files in place. Every target is copied to a
# temp directory up front and restored by an EXIT/INT/TERM trap, then verified
# byte-for-byte against its backup before the script returns — so a Ctrl-C mid-run
# leaves the tree as it found it. It does not need (or want) a clean git tree.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# The pure-logic engine files: no syscalls, no Accessibility, no network, so every
# line is reachable from a unit test and a survivor means a missing assertion
# rather than a missing environment. Keep this list to files whose logic is
# decision-making — adding a syscall wrapper here produces guaranteed survivors
# (nothing exercises those lines) that drown the real signal.
DEFAULT_TARGETS=(
  "Sources/BlurtEngine/Config/APIKeyDisplay.swift"
  "Sources/BlurtEngine/Config/APIKeyValidator.swift"
  "Sources/BlurtEngine/FocusCapture/FocusCapture+Pure.swift"
  "Sources/BlurtEngine/Hotkey/DictationKeyGate.swift"
  "Sources/BlurtEngine/Hotkey/DictationKeyRouter.swift"
  "Sources/BlurtEngine/Hotkey/TriggerKey.swift"
  "Sources/BlurtEngine/Injection/KeyInjector+Separator.swift"
  "Sources/BlurtEngine/Pipeline/MeterBarGeometry.swift"
  "Sources/BlurtEngine/Pipeline/OverlayPlacement.swift"
  "Sources/BlurtEngine/Pipeline/PipelinePhase.swift"
  "Sources/BlurtEngine/Pipeline/RecordingCueGate.swift"
  "Sources/BlurtEngine/STT/ConversationContext.swift"
  "Sources/BlurtEngine/STT/KeytermsBoost.swift"
  "Sources/BlurtEngine/STT/SyncSTTLimits.swift"
  "Sources/BlurtEngine/StringNormalization.swift"
  "Sources/BlurtEngine/Update/AutomaticUpdateCheck.swift"
  "Sources/BlurtEngine/Update/SemanticVersion.swift"
  "Sources/BlurtEngine/Update/UpdateAlertContent.swift"
)

MAX_MUTANTS=0 # 0 = no cap
LIST_ONLY=0
TARGETS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --max)
      MAX_MUTANTS="${2:?--max needs a count}"
      shift 2
      ;;
    --files)
      # shellcheck disable=SC2206  # deliberate word-split of a space-separated list
      TARGETS=(${2:?--files needs a space-separated list})
      shift 2
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    -h | --help)
      # The whole header block is the help text; keep this range in step with it.
      sed -n '2,35p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1' (see --help)" >&2
      exit 2
      ;;
  esac
done

[ "${#TARGETS[@]}" -gt 0 ] || TARGETS=("${DEFAULT_TARGETS[@]}")

for f in "${TARGETS[@]}"; do
  [ -f "$f" ] || {
    echo "error: target not found: $f" >&2
    exit 1
  }
done

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 not found — needed to enumerate and apply mutants" >&2
  exit 1
}

WORK="$(mktemp -d)"
BACKUP="$WORK/backup"
mkdir -p "$BACKUP"

# Restore before anything else can look at the tree, and make it idempotent so the
# explicit call at the end and the trap can't fight. `cp` by flattened name because
# two targets can share a basename only if their paths differ, which the encoding
# below preserves.
restore_all() {
  for file in "${TARGETS[@]}"; do
    saved="$BACKUP/$(printf '%s' "$file" | tr '/' '_')"
    [ -f "$saved" ] && cp "$saved" "$file"
  done
}
# The group kill is necessary but not sufficient: `xctest` puts itself in a *new*
# process group (observed with PGID == its own PID and PPID 1 after a timeout), so
# signalling `swift-test`'s group cannot reach it, and the orphan keeps holding the
# build directory — which makes the *next* mutant fail for an unrelated reason and
# report as killed. Sweep it by the absolute path of this checkout's test bundle, so
# the match can't reach another clone, another project, or another user's xctest.
#
# The one thing this would catch unfairly is a `swift test` the developer is running
# by hand in this same repo — but that shares `.build` with this script anyway, so
# the two cannot run concurrently regardless.
reap_orphaned_xctest() {
  local pids
  pids="$(pgrep -f "xctest .*$REPO_ROOT/\.build/" 2>/dev/null || true)"
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086  # deliberate word-split: pgrep emits one pid per line
  kill -TERM $pids 2>/dev/null || true
  sleep 1
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null || true
}

# Ctrl-C during a hung suite has to sweep too, or the orphan outlives the script.
trap 'restore_all; reap_orphaned_xctest; rm -rf "$WORK"' EXIT INT TERM

for file in "${TARGETS[@]}"; do
  cp "$file" "$BACKUP/$(printf '%s' "$file" | tr '/' '_')"
done

# ---------------------------------------------------------------------------
# Enumeration
#
# In python rather than sed/awk because the operators are the characters those
# tools treat as special (`&` in a sed replacement means the whole match, `|` and
# `.` are regex syntax), so a shell implementation would spend its complexity on
# escaping instead of on the part that matters: knowing which characters on a line
# are *code*. This repo is comment-dense and uses multi-line string literals for
# log messages, and a mutant planted in prose is guaranteed to survive — it would
# report as a finding while proving nothing. So the scanner tracks string and
# comment state and emits offsets into code only.
#
# Emits one TSV row per mutant: path, 1-based line, 0-based column, from, to.
# ---------------------------------------------------------------------------
enumerate() {
  python3 - "$@" <<'PY'
import sys

# from -> to, tried in this order. Longest-first within a prefix family (">=" before
# ">") is not needed because the bare "<" / ">" swaps are deliberately absent: Swift
# spells returns as "->" and generics as "<T>", so mutating a lone angle bracket
# mostly yields code that doesn't compile — an invalid mutant costs a full build to
# learn nothing. Same reasoning excludes "+"/"-" (unary, string concat, and Duration
# arithmetic all overload them).
OPERATORS = [
    ("&&", "||"),
    ("||", "&&"),
    ("==", "!="),
    ("!=", "=="),
    (">=", "<"),
    ("<=", ">"),
    ("min(", "max("),
    ("max(", "min("),
    (".first", ".last"),
    (".last", ".first"),
    ("true", "false"),
    ("false", "true"),
]

# Word-ish operators must not match inside an identifier (`trueValue`, `isFalse`).
IDENT = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
WORDY = {"true", "false"}


def code_spans(lines):
    """Yield (line_index, start, end) spans that are code — not comment, not string.

    Handles line comments, block comments, single-quoted strings with escapes, and
    triple-quoted multi-line strings. (Spelling that last delimiter out here would
    close this docstring, which is how the first draft of this scanner failed.) Raw
    strings are absent from this codebase; if that changes, a mutant landing inside
    one surfaces as an unkillable survivor rather than as silence, which is the
    failure mode to prefer.
    """
    in_multiline = False
    in_block_comment = False
    for i, line in enumerate(lines):
        j, span_start = 0, None
        n = len(line)
        while j < n:
            if in_multiline:
                if line.startswith('"""', j):
                    in_multiline = False
                    j += 3
                else:
                    j += 1
                continue
            if in_block_comment:
                if line.startswith("*/", j):
                    in_block_comment = False
                    j += 2
                else:
                    j += 1
                continue
            if line.startswith('"""', j):
                if span_start is not None:
                    yield (i, span_start, j)
                    span_start = None
                in_multiline = True
                j += 3
                continue
            if line.startswith("//", j):
                break  # rest of the line is comment
            if line.startswith("/*", j):
                if span_start is not None:
                    yield (i, span_start, j)
                    span_start = None
                in_block_comment = True
                j += 2
                continue
            if line[j] == '"':
                if span_start is not None:
                    yield (i, span_start, j)
                    span_start = None
                j += 1
                while j < n:
                    if line[j] == "\\":
                        j += 2
                        continue
                    if line[j] == '"':
                        j += 1
                        break
                    j += 1
                continue
            if span_start is None:
                span_start = j
            j += 1
        if span_start is not None:
            yield (i, span_start, j)


for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    for idx, start, end in code_spans(lines):
        # Escape hatch, spelled the same way as check-portability.sh's
        # `# portable-ok:`. It exists for *equivalent* mutants: a change that provably
        # cannot alter behaviour, so no test can be written to catch it. Without a way
        # to retire those, they resurface as survivors on every run and train the
        # reader to skim a list whose whole value is that every entry is actionable.
        if "// mutate-ok:" in lines[idx]:
            continue
        segment = lines[idx][start:end]
        for frm, to in OPERATORS:
            pos = 0
            while True:
                hit = segment.find(frm, pos)
                if hit < 0:
                    break
                pos = hit + 1
                if frm in WORDY:
                    before = segment[hit - 1] if hit > 0 else ""
                    after_at = hit + len(frm)
                    after = segment[after_at] if after_at < len(segment) else ""
                    if before in IDENT or after in IDENT:
                        continue
                print(f"{path}\t{idx + 1}\t{start + hit}\t{frm}\t{to}")
PY
}

# Replace exactly one occurrence, located by line and column, so a line carrying
# two `==` yields two distinct mutants instead of one compound edit.
apply_mutant() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import sys

path, line_no, col, frm, to = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().split("\n")
line = lines[line_no - 1]
assert line[col:col + len(frm)] == frm, f"{path}:{line_no}:{col} no longer holds {frm!r}"
lines[line_no - 1] = line[:col] + to + line[col + len(frm):]
with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines))
PY
}

# Bound every build and suite run. A mutant can make a test await a condition that
# is now never satisfied — flipping a `PipelinePhase` predicate does exactly that —
# and `swift test` has no timeout of its own, so an unbounded harness wedges
# indefinitely on the first such mutant. (The first draft of this script sat on one
# for 35 minutes against a suite that normally finishes in ~1.2 s.)
#
# GNU `timeout` is not present on macOS — `check-portability.sh` flags it for that
# reason — so this polls a backgrounded job instead. `set -m` puts that job in its
# own process group so the kill reaches the `xctest` grandchild: signalling only
# `swift-test` leaves the hung test binary orphaned, still holding the build
# directory, and the next mutant then fails for an unrelated reason.
TEST_DEADLINE_SECONDS=60
BUILD_DEADLINE_SECONDS=300

# Returns the command's status, or 124 if it hit the deadline (mirroring what
# `timeout` would report, so the caller reads the same way).
run_bounded() {
  local deadline=$1
  shift
  local pid waited=0
  set -m
  "$@" >/dev/null 2>&1 &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$deadline" ]; then
      kill -TERM -- "-$pid" 2>/dev/null || true
      sleep 1
      kill -KILL -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      reap_orphaned_xctest
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  local status=0
  wait "$pid" || status=$?
  return "$status"
}

LIST="$WORK/mutants.tsv"
enumerate "${TARGETS[@]}" >"$LIST"
TOTAL="$(wc -l <"$LIST" | tr -d ' ')"

if [ "$MAX_MUTANTS" -gt 0 ] && [ "$TOTAL" -gt "$MAX_MUTANTS" ]; then
  head -n "$MAX_MUTANTS" "$LIST" >"$LIST.capped"
  mv "$LIST.capped" "$LIST"
  echo "note: capping at $MAX_MUTANTS of $TOTAL mutants (--max) — the score below"
  echo "      describes the sample, not the target set"
  TOTAL="$MAX_MUTANTS"
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  awk -F'\t' '{ printf "%s:%s  %s -> %s\n", $1, $2, $4, $5 }' "$LIST"
  echo "$TOTAL mutants across ${#TARGETS[@]} files"
  exit 0
fi

echo "==> baseline (the suite must be green before a mutant means anything)"
# Without this, a suite that is already red reports every mutant as killed — a
# perfect score that measures nothing.
if ! swift build --build-tests >/dev/null 2>&1; then
  echo "error: baseline build failed — fix that first" >&2
  exit 1
fi
if ! swift test >/dev/null 2>&1; then
  echo "error: baseline suite is red — fix that first, or every mutant reports killed" >&2
  exit 1
fi
echo "baseline green"

echo "==> $TOTAL mutants (~7s each, so roughly $(((TOTAL * 7 + 59) / 60)) min)"

KILLED=0
SURVIVED=0
INVALID=0
TIMED_OUT=0
SURVIVORS="$WORK/survivors.txt"
: >"$SURVIVORS"

INDEX=0
# fd 3 so `swift test` inheriting stdin can't consume the mutant list.
while IFS=$'\t' read -r file line col frm to <&3; do
  INDEX=$((INDEX + 1))
  printf '[%d/%d] %s:%s  %s -> %s  ' "$INDEX" "$TOTAL" "$file" "$line" "$frm" "$to"

  apply_mutant "$file" "$line" "$col" "$frm" "$to"

  if ! run_bounded "$BUILD_DEADLINE_SECONDS" swift build --build-tests; then
    # The mutant doesn't compile. Counted separately, never as killed: a build
    # error is the compiler objecting, not a test, and folding it into the kill
    # count is how a mutation score flatters itself.
    INVALID=$((INVALID + 1))
    echo "invalid (does not compile)"
  else
    TEST_STATUS=0
    run_bounded "$TEST_DEADLINE_SECONDS" swift test || TEST_STATUS=$?
    case "$TEST_STATUS" in
      0)
        SURVIVED=$((SURVIVED + 1))
        printf '%s:%s\t%s -> %s\n' "$file" "$line" "$frm" "$to" >>"$SURVIVORS"
        echo "SURVIVED"
        ;;
      124)
        # A mutant that hangs the suite changed behaviour observably, so it counts
        # as killed — but by a test's *liveness* rather than by an assertion, which
        # is worth telling apart when reading the score.
        KILLED=$((KILLED + 1))
        TIMED_OUT=$((TIMED_OUT + 1))
        echo "killed (timed out after ${TEST_DEADLINE_SECONDS}s)"
        ;;
      *)
        KILLED=$((KILLED + 1))
        echo "killed"
        ;;
    esac
  fi

  restore_all
done 3<"$LIST"

restore_all
for file in "${TARGETS[@]}"; do
  saved="$BACKUP/$(printf '%s' "$file" | tr '/' '_')"
  cmp -s "$saved" "$file" || {
    echo "error: $file did not restore cleanly — compare against $saved before committing" >&2
    exit 1
  }
done

echo
echo "==> results"
echo "killed:    $KILLED  (of which $TIMED_OUT by hanging the suite, not by an assertion)"
echo "survived:  $SURVIVED"
echo "invalid:   $INVALID  (did not compile — excluded from the score)"
SCORED=$((KILLED + SURVIVED))
if [ "$SCORED" -gt 0 ]; then
  echo "score:     $((KILLED * 100 / SCORED))%  ($KILLED/$SCORED viable mutants killed)"
fi

if [ "$SURVIVED" -gt 0 ]; then
  echo
  echo "==> survivors — each is a behaviour change no test objected to"
  echo "    (some will be equivalent mutants that cannot change behaviour; that"
  echo "     judgement is yours, which is why this isn't a gate)"
  sort "$SURVIVORS" | awk -F'\t' '{ printf "  %-58s %s\n", $1, $2 }'
fi

# Exit 0 regardless of survivors: this is a report, not a gate. `check.sh` owns
# green/not-green, and it does not call this script.
