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
# hand, and treat survivors as a to-do list. CI runs it daily
# (.github/workflows/mutate.yml) and opens a pull request for what survives.
#
# Usage:
#   scripts/mutate.sh                       # all mutants in the default target set
#   scripts/mutate.sh --max 40              # stop after 40 mutants
#   scripts/mutate.sh --files "a.swift b.swift"
#   scripts/mutate.sh --list                # enumerate mutants, run nothing
#   scripts/mutate.sh --shard 2/6           # every 6th mutant from the 2nd (CI)
#   scripts/mutate.sh --results out.tsv     # one "outcome<TAB>file<TAB>line<TAB>from<TAB>to" row per mutant
#   scripts/mutate.sh --strict              # exit 3 if any mutant survives
#   scripts/mutate.sh --suite ios           # the iPhone core (BlurtiOSCore) on a simulator
#   scripts/mutate.sh --print-targets       # the suite's default target list, one per line
#
# Two suites. `engine` (the default) mutates the Swift package's sources and runs
# `swift test`; `ios` mutates BlurtiOSCore and runs BlurtiOSTests on a simulator
# through xcodebuild, the way scripts/ios-test.sh does, at ~5x the cost per
# mutant. With --files and no --suite, the suite follows the files' paths.
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
  "Sources/AssemblyAI/APIKeyValidator.swift"
  "Sources/AssemblyAI/Dictation/KeyTerms.swift"
  "Sources/AssemblyAI/Dictation/DictationPrompt.swift"
  "Sources/BlurtEngine/Pipeline/TextShortcut.swift"
  "Sources/BlurtEngine/FocusCapture/FocusCapture+Pure.swift"
  "Sources/BlurtEngine/Hotkey/DictationKeyGate.swift"
  "Sources/BlurtEngine/Hotkey/DictationKeyRouter.swift"
  "Sources/BlurtEngine/Hotkey/TriggerKey.swift"
  "Sources/BlurtEngine/Injection/InsertionSeparator.swift"
  "Sources/BlurtEngine/Pipeline/MeterBarGeometry.swift"
  "Sources/BlurtEngine/Pipeline/OverlayPlacement.swift"
  "Sources/BlurtEngine/Pipeline/PipelinePhase.swift"
  "Sources/BlurtEngine/Pipeline/RecordingCueGate.swift"
  "Sources/BlurtAssemblyAI/STTPrompt.swift"
  "Sources/BlurtEngine/STT/RecordingLimits.swift"
  "Sources/BlurtEngine/String+Normalization.swift"
  # Control Your Mac's decisions: the reply parser and its checks, name
  # matching and the destructive guard, the screen read over any tree, the
  # press/focus/menu choices apart from Accessibility, window layout, the
  # per-app notes, and the complaint and trace helpers. The Accessibility
  # shell around them (SystemVoiceCommandPerformer*) is no target: nothing
  # unit-tests those lines, so every mutant there would survive.
  "Sources/BlurtEngine/Command/VoiceCommandStep+Parse.swift"
  "Sources/BlurtEngine/Command/NameMatch.swift"
  "Sources/BlurtEngine/Command/ScreenRead.swift"
  "Sources/BlurtEngine/Command/ScreenContext.swift"
  "Sources/BlurtEngine/Command/ElementActions.swift"
  "Sources/BlurtEngine/Command/WindowLayout.swift"
  "Sources/BlurtEngine/Command/AppNotes.swift"
  "Sources/BlurtEngine/Command/PlanTrace.swift"
  "Sources/BlurtEngine/Command/VoiceCommandStep.swift"
  "Sources/BlurtEngine/Command/VoiceCommandPlanner.swift"
  "Sources/BlurtEngine/Command/ElementSnapshot.swift"
  "Sources/BlurtEngine/Command/EnhancedInterface.swift"
  # The press routing and the command log around it, and the paste decision
  # the recorded paste fixtures replay.
  "Sources/BlurtEngine/Hotkey/SelectionSpeechRouting.swift"
  "Sources/BlurtEngine/Hotkey/SelectionSpeechRouting+Types.swift"
  "Sources/BlurtEngine/Pipeline/DictationLog+Commands.swift"
  "Sources/BlurtEngine/FocusCapture/PasteTarget.swift"
)

# The iPhone core's decision-making files: the press handshake between the
# keyboard and the app, the listening window's state machine, the command
# router, and the state, notice and stats rules the keyboard and Home show —
# Foundation only, every line reachable from BlurtiOSTests. Not the
# KeyboardModel extensions (UIKit, driven through the text proxy) or the App
# Group and Darwin-notification plumbing (SharedStore, DarwinObserver), whose
# lines say "nothing reaches this from a unit test", not "nothing asserts it".
DEFAULT_IOS_TARGETS=(
  "App/BlurtiOS/BlurtiOSCore/PressHandshake.swift"
  "App/BlurtiOS/BlurtiOSCore/PressHandshake+Stop.swift"
  "App/BlurtiOS/BlurtiOSCore/PressHandshake+Types.swift"
  "App/BlurtiOS/BlurtiOSCore/ListeningWindowMachine.swift"
  "App/BlurtiOS/BlurtiOSCore/ListeningWindowMachine+Moves.swift"
  "App/BlurtiOS/BlurtiOSCore/ListeningWindowMachine+Types.swift"
  "App/BlurtiOS/BlurtiOSCore/ListeningState.swift"
  "App/BlurtiOS/BlurtiOSCore/CommandRouter.swift"
  "App/BlurtiOS/BlurtiOSCore/KeyboardCommand.swift"
  "App/BlurtiOS/BlurtiOSCore/BlurtShared+SessionContract.swift"
  "App/BlurtiOS/BlurtiOSCore/PhaseSnapshot.swift"
  "App/BlurtiOS/BlurtiOSCore/VoiceState.swift"
  "App/BlurtiOS/BlurtiOSCore/VoiceNotice.swift"
  "App/BlurtiOS/BlurtiOSCore/HomeStatus.swift"
  "App/BlurtiOS/BlurtiOSCore/DictationStats.swift"
  "App/BlurtiOS/BlurtiOSCore/StatFormat.swift"
  "App/BlurtiOS/BlurtiOSCore/TypingSpeed.swift"
  "App/BlurtiOS/BlurtiOSCore/Bounce.swift"
  "App/BlurtiOS/BlurtiOSCore/KeepOpen.swift"
  "App/BlurtiOS/BlurtiOSCore/OwnerWatchdog.swift"
  "App/BlurtiOS/BlurtiOSCore/SessionAutoStart.swift"
  "App/BlurtiOS/BlurtiOSCore/AIConsent.swift"
)
IOS_PREFIX="App/BlurtiOS/"

MAX_MUTANTS=0 # 0 = no cap
SHARD_INDEX=1
SHARD_COUNT=1
LIST_ONLY=0
PRINT_TARGETS=0
SUITE=""
STRICT=0
RESULTS=""
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
    --shard)
      # K/N: keep mutants K, K+N, K+2N, … (1-based), so N parallel runners
      # (.github/workflows/mutate.yml) split the set evenly whatever the files.
      SHARD="${2:?--shard needs K/N}"
      SHARD_INDEX="${SHARD%%/*}"
      SHARD_COUNT="${SHARD##*/}"
      case "$SHARD_INDEX$SHARD_COUNT" in
        '' | *[!0-9]*)
          echo "error: --shard wants K/N, got '$SHARD'" >&2
          exit 2
          ;;
      esac
      if [ "$SHARD_COUNT" -lt 1 ] || [ "$SHARD_INDEX" -lt 1 ] || [ "$SHARD_INDEX" -gt "$SHARD_COUNT" ]; then
        echo "error: --shard wants 1 <= K <= N, got '$SHARD'" >&2
        exit 2
      fi
      shift 2
      ;;
    --results)
      RESULTS="${2:?--results needs a file}"
      shift 2
      ;;
    --strict)
      # A survivor fails the run, for a caller that wants a gate. Off by default
      # because a run is a to-do list; CI (.github/workflows/mutate.yml) leaves
      # it off too and judges the merged results in its `report` job instead.
      STRICT=1
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --suite)
      SUITE="${2:?--suite needs engine or ios}"
      case "$SUITE" in
        engine | ios) ;;
        *)
          echo "error: --suite wants engine or ios, got '$SUITE'" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --print-targets)
      PRINT_TARGETS=1
      shift
      ;;
    -h | --help)
      # The whole header block is the help text; keep this range in step with it.
      sed -n '2,46p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1' (see --help)" >&2
      exit 2
      ;;
  esac
done

# --files without --suite: the files say which suite. A mix can't run under
# one test command, so it is refused rather than half-tested.
if [ -z "$SUITE" ] && [ "${#TARGETS[@]}" -gt 0 ]; then
  ios_files=0
  for f in "${TARGETS[@]}"; do
    case "$f" in "$IOS_PREFIX"*) ios_files=$((ios_files + 1)) ;; esac
  done
  if [ "$ios_files" -eq "${#TARGETS[@]}" ]; then
    SUITE=ios
  elif [ "$ios_files" -eq 0 ]; then
    SUITE=engine
  else
    echo "error: --files mixes iPhone ($IOS_PREFIX) and engine files; run each suite on its own" >&2
    exit 2
  fi
fi
SUITE="${SUITE:-engine}"

if [ "${#TARGETS[@]}" -eq 0 ]; then
  if [ "$SUITE" = ios ]; then
    TARGETS=("${DEFAULT_IOS_TARGETS[@]}")
  else
    TARGETS=("${DEFAULT_TARGETS[@]}")
  fi
fi

if [ "$PRINT_TARGETS" -eq 1 ]; then
  printf '%s\n' "${TARGETS[@]}"
  exit 0
fi

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
    # An `if`, not `&&`: with no backup (--list) a false test would be the loop's
    # last status and, under errexit, fail the EXIT trap and so the whole script.
    if [ -f "$saved" ]; then cp "$saved" "$file"; fi
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

# --list never edits a target, so it skips the backup — and with it the restore's
# `cp` back over each file, which would bump every target's mtime and cost
# check.sh (which runs --list ahead of its Swift build) a needless recompile.
if [ "$LIST_ONLY" -eq 0 ]; then
  for file in "${TARGETS[@]}"; do
    cp "$file" "$BACKUP/$(printf '%s' "$file" | tr '/' '_')"
  done
fi

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

# from -> to, tried in this order. Two families.
#
# Negations (`>=` -> `<`, `==` -> `!=`, ...) invert a decision; nearly any test
# that sees both outcomes kills them. Boundaries (`>=` -> `>`, `<` -> `<=`, ...)
# move it by one, which is the off-by-one a test that only checks the far sides
# never notices — the more valuable half.
#
# The angle brackets and arithmetic are matched only with a space on each side.
# Swift requires a binary operator's whitespace to be the same on both sides
# (`a<b` or `a < b`, never `a <b`), swift-format always spaces them, and generics
# (`Array<Int>`), returns (`->`), unary minus (`-x`) and ranges (`..<`) never
# take a space on both sides — so " < " is always a comparison and " - " always
# a subtraction. A bare "<" / "-" would mostly mutate generics and returns into
# code that doesn't compile: a full build to learn nothing. " + " is still out:
# string concatenation overloads it, and the 5x-more-common string case would
# drown the arithmetic one in invalid or equivalent mutants.
OPERATORS = [
    ("&&", "||"),
    ("||", "&&"),
    ("==", "!="),
    ("!=", "=="),
    (">=", "<"),
    ("<=", ">"),
    (" >= ", " > "),
    (" <= ", " < "),
    (" > ", " >= "),
    (" < ", " <= "),
    (" - ", " + "),
    (" -= ", " += "),
    (" += 1", " -= 1"),
    (" * ", " / "),
    (" / ", " * "),
    ("min(", "max("),
    ("max(", "min("),
    (".first", ".last"),
    (".last", ".first"),
    ("true", "false"),
    ("false", "true"),
    # Dropping a prefix `!` (see NEGATION_BEFORE below): a missing negation.
    ("!", ""),
]

# A prefix `!` is a negation only where an operand can start: after one of these
# (or at the start of the line) and before an identifier, `(` or `.`. That rules
# out `!=`, a force unwrap (`x!`, `f()!`, `a[0]!`), `try!` and `as!`.
NEGATION_BEFORE = set(" \t([{,:=&|?")
NEGATION_AFTER = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_($.")

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
                if frm == "!":
                    line = lines[idx]
                    at = start + hit
                    before = line[at - 1] if at > 0 else " "
                    after = line[at + 1] if at + 1 < len(line) else ""
                    if before not in NEGATION_BEFORE or after not in NEGATION_AFTER:
                        continue
                if frm[-1].isdigit():
                    # " += 1" must not match " += 10".
                    end_at = start + hit + len(frm)
                    if end_at < len(lines[idx]) and lines[idx][end_at] in IDENT:
                        continue
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
# Overridable because a shared CI runner is slower than a developer's Mac, and a
# deadline the *unmutated* suite can miss reports mutants as killed by timeout.
# Unset, it is derived from the baseline run below (5x, floor 60s), so a slow
# runner needs no tuning.
TEST_DEADLINE_SECONDS="${MUTATE_TEST_DEADLINE_SECONDS:-}"
BUILD_DEADLINE_SECONDS="${MUTATE_BUILD_DEADLINE_SECONDS:-300}"

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
      reap_after_timeout
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  local status=0
  wait "$pid" || status=$?
  return "$status"
}

# What "build" and "test" mean for each suite. The engine is a Swift package;
# the iPhone core builds and tests only through its Xcode project, on a
# simulator, with ios-test.sh's recipe (scripts/ios-lib.sh) minus the coverage
# instrumentation, which would only slow every mutant down. Parallel testing is
# off for the iPhone suite: xcodebuild runs parallel tests on simulator clones,
# and a mutant that hangs the suite would leave those clones booted when the
# deadline kills it. One simulator, one runner, one thing to clean up.
IOS_HOST_APP="com.assemblyai.blurt.iphone"
ios_setup() {
  # shellcheck source=scripts/release-lib.sh
  source "$REPO_ROOT/scripts/release-lib.sh"
  # shellcheck source=scripts/ios-lib.sh
  source "$REPO_ROOT/scripts/ios-lib.sh"
  ios_require_device mutate
  echo "simulator: $NAME"
  ios_boot_async "$UDID"
  ios_generate_project
  IOS_MUTATE_DERIVED="$IOS_DERIVED-mutate"
  ios_resolve_packages "$IOS_MUTATE_DERIVED"
  IOS_ARGS=(-project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" -scheme BlurtiOS
    -derivedDataPath "$IOS_MUTATE_DERIVED" "${IOS_SIM_SIGNING[@]}" -enableCodeCoverage NO)
}
suite_build() {
  if [ "$SUITE" = ios ]; then
    xcodebuild build-for-testing -quiet "${IOS_ARGS[@]}" "${IOS_SIM_BUILD[@]}"
  else
    swift build --build-tests
  fi
}
suite_test() {
  if [ "$SUITE" = ios ]; then
    xcodebuild test-without-building -quiet "${IOS_ARGS[@]}" \
      -destination "platform=iOS Simulator,id=$UDID" -only-testing:BlurtiOSTests \
      -parallel-testing-enabled NO -collect-test-diagnostics never
  else
    swift test
  fi
}
# After a deadline kill: the engine's orphan is an xctest process (see
# reap_orphaned_xctest); the iPhone's is the host app still running the tests
# on the simulator, which the next mutant's run would otherwise queue behind.
reap_after_timeout() {
  reap_orphaned_xctest
  if [ "$SUITE" = ios ]; then
    xcrun simctl terminate "$UDID" "$IOS_HOST_APP" >/dev/null 2>&1 || true
  fi
}
# Display form of an operator: the spaces that pin " < " to a comparison are
# matching detail, and an empty replacement (a dropped `!`) needs a word.
show_op() {
  local op="$1"
  op="${op#"${op%%[! ]*}"}"
  op="${op%"${op##*[! ]}"}"
  printf '%s' "${op:-(dropped)}"
}

LIST="$WORK/mutants.tsv"
enumerate "${TARGETS[@]}" >"$LIST"
if [ "$SHARD_COUNT" -gt 1 ]; then
  awk -v k="$SHARD_INDEX" -v n="$SHARD_COUNT" '(NR - 1) % n == k - 1' "$LIST" >"$LIST.shard"
  mv "$LIST.shard" "$LIST"
fi
TOTAL="$(wc -l <"$LIST" | tr -d ' ')"

if [ "$MAX_MUTANTS" -gt 0 ] && [ "$TOTAL" -gt "$MAX_MUTANTS" ]; then
  head -n "$MAX_MUTANTS" "$LIST" >"$LIST.capped"
  mv "$LIST.capped" "$LIST"
  echo "note: capping at $MAX_MUTANTS of $TOTAL mutants (--max) — the score below"
  echo "      describes the sample, not the target set"
  TOTAL="$MAX_MUTANTS"
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  awk -F'\t' '{ printf "%s:%s  %s -> %s\n", $1, $2, show($4), show($5) }
    function show(op) { gsub(/^ +| +$/, "", op); return op == "" ? "(dropped)" : op }' "$LIST"
  echo "$TOTAL mutants across ${#TARGETS[@]} files"
  exit 0
fi

if [ "$SUITE" = ios ]; then ios_setup; fi

echo "==> baseline: $SUITE suite (it must be green before a mutant means anything)"
# Without this, a suite that is already red reports every mutant as killed — a
# perfect score that measures nothing.
if ! suite_build >/dev/null 2>&1; then
  echo "error: baseline build failed — fix that first" >&2
  exit 1
fi
if [ "$SUITE" = ios ]; then ios_wait_booted "$UDID"; fi
BASELINE_START=$SECONDS
if ! suite_test >/dev/null 2>&1; then
  echo "error: baseline suite is red — fix that first, or every mutant reports killed" >&2
  exit 1
fi
BASELINE_SECONDS=$((SECONDS - BASELINE_START))
if [ -z "$TEST_DEADLINE_SECONDS" ]; then
  TEST_DEADLINE_SECONDS=$((BASELINE_SECONDS * 5))
  [ "$TEST_DEADLINE_SECONDS" -ge 60 ] || TEST_DEADLINE_SECONDS=60
fi
echo "baseline green (suite ${BASELINE_SECONDS}s; per-mutant deadline ${TEST_DEADLINE_SECONDS}s)"

# The estimate: an engine mutant is ~7 s (an incremental build and a ~1 s
# suite); an iPhone one is its incremental build plus the measured suite.
if [ "$SUITE" = ios ]; then PER_MUTANT=$((BASELINE_SECONDS + 20)); else PER_MUTANT=7; fi
echo "==> $TOTAL mutants (~${PER_MUTANT}s each, so roughly $(((TOTAL * PER_MUTANT + 59) / 60)) min)"

KILLED=0
SURVIVED=0
INVALID=0
TIMED_OUT=0
SURVIVORS="$WORK/survivors.txt"
: >"$SURVIVORS"
# Machine-readable outcome per mutant, so CI aggregates shards without scraping
# the progress lines above.
if [ -n "$RESULTS" ]; then : >"$RESULTS"; fi
record() {
  if [ -n "$RESULTS" ]; then printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$file" "$line" "$shown_frm" "$shown_to" >>"$RESULTS"; fi
}

INDEX=0
# fd 3 so `swift test` inheriting stdin can't consume the mutant list.
while IFS=$'\t' read -r file line col frm to <&3; do
  INDEX=$((INDEX + 1))
  shown_frm="$(show_op "$frm")"
  shown_to="$(show_op "$to")"
  printf '[%d/%d] %s:%s  %s -> %s  ' "$INDEX" "$TOTAL" "$file" "$line" "$shown_frm" "$shown_to"

  apply_mutant "$file" "$line" "$col" "$frm" "$to"

  if ! run_bounded "$BUILD_DEADLINE_SECONDS" suite_build; then
    # The mutant doesn't compile. Counted separately, never as killed: a build
    # error is the compiler objecting, not a test, and folding it into the kill
    # count is how a mutation score flatters itself.
    INVALID=$((INVALID + 1))
    echo "invalid (does not compile)"
    record invalid
  else
    TEST_STATUS=0
    run_bounded "$TEST_DEADLINE_SECONDS" suite_test || TEST_STATUS=$?
    case "$TEST_STATUS" in
      0)
        SURVIVED=$((SURVIVED + 1))
        printf '%s:%s\t%s -> %s\n' "$file" "$line" "$shown_frm" "$shown_to" >>"$SURVIVORS"
        echo "SURVIVED"
        record survived
        # Under GitHub Actions, an annotation pins the survivor to its line in
        # the run's summary and in any diff that touches it.
        if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
          echo "::warning file=$file,line=$line,title=Mutant survived::$shown_frm -> $shown_to changed behaviour and no test failed"
        fi
        ;;
      124)
        # A mutant that hangs the suite changed behaviour observably, so it counts
        # as killed — but by a test's *liveness* rather than by an assertion, which
        # is worth telling apart when reading the score.
        KILLED=$((KILLED + 1))
        TIMED_OUT=$((TIMED_OUT + 1))
        echo "killed (timed out after ${TEST_DEADLINE_SECONDS}s)"
        record timeout
        ;;
      *)
        KILLED=$((KILLED + 1))
        echo "killed"
        record killed
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

# Exit 0 regardless of survivors unless --strict: this is a report, not a gate.
# `check.sh` owns green/not-green, and it does not call this script.
if [ "$STRICT" -eq 1 ] && [ "$SURVIVED" -gt 0 ]; then
  exit 3
fi
