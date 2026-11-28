#!/bin/bash
# Files that look ready for mutation testing but aren't in mutate.sh's target
# lists: well covered by the suite, with mutants to try. A suggestion list for a
# person to judge, never an automatic addition — a file can be fully covered and
# still be the wrong target (a syscall wrapper whose lines run but whose results
# no unit test can see), and only someone reading it can tell.
#
#   scripts/mutate-candidates.sh                     # engine: swift test with coverage, then the list
#   scripts/mutate-candidates.sh --suite ios         # iPhone: scripts/ios-test.sh, then the list
#   scripts/mutate-candidates.sh --min 90            # coverage floor in percent (default 95)
#   scripts/mutate-candidates.sh --out cands.md      # also write the list as Markdown
#
# A candidate is a non-test Swift file of the suite (Sources/ for the engine,
# App/BlurtiOS/ for the iPhone) with at least --min% line coverage, at least
# MIN_LINES executable lines, at least MIN_MUTANTS mutants as mutate.sh
# enumerates them, and not already a target. A file that has been judged and
# turned down carries `// mutate-not-target: <reason>` anywhere in it, and is
# never suggested again.
#
# macOS only: the coverage comes from a real test run. CI runs it daily in the
# `mutate` workflow and lists the result in the survivors issue.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SUITE=engine
MIN_COVERAGE=95
MIN_LINES=10
MIN_MUTANTS=3
OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --suite)
      SUITE="${2:?--suite needs engine or ios}"
      shift 2
      ;;
    --min)
      MIN_COVERAGE="${2:?--min needs a percentage}"
      shift 2
      ;;
    --out)
      OUT="${2:?--out needs a file}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,23p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1' (see --help)" >&2
      exit 2
      ;;
  esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
COVERAGE="$WORK/coverage.tsv" # path<TAB>covered<TAB>executable, repo-relative

case "$SUITE" in
  engine)
    echo "==> swift test --enable-code-coverage"
    swift test --enable-code-coverage >/dev/null
    BIN="$(swift build --show-bin-path)"
    PROFDATA="$BIN/codecov/default.profdata"
    XCTEST_BUNDLE="$(find "$BIN" -maxdepth 1 -name '*Tests.xctest' -print -quit)"
    XCTEST_BIN="$XCTEST_BUNDLE/Contents/MacOS/$(basename "$XCTEST_BUNDLE" .xctest)"
    [ -f "$PROFDATA" ] && [ -f "$XCTEST_BIN" ] || {
      echo "error: no coverage profile or test binary under $BIN" >&2
      exit 1
    }
    xcrun llvm-cov export -summary-only -instr-profile "$PROFDATA" "$XCTEST_BIN" | python3 -c '
import json, sys
root = sys.argv[1] + "/"
for f in json.load(sys.stdin)["data"][0]["files"]:
    path = f["filename"]
    if not path.startswith(root + "Sources/"):
        continue
    lines = f["summary"]["lines"]
    covered, count = lines["covered"], lines["count"]
    print(f"{path[len(root):]}\t{covered}\t{count}")
' "$REPO_ROOT" >"$COVERAGE"
    ;;
  ios)
    echo "==> scripts/ios-test.sh"
    LOG="$WORK/ios-test.log"
    scripts/ios-test.sh >"$LOG" 2>&1 || {
      tail -40 "$LOG" >&2
      echo "error: ios-test.sh failed — candidates need a green run" >&2
      exit 1
    }
    RESULTS="$(sed -n 's/^results: //p' "$LOG" | tail -1)"
    [ -d "$RESULTS" ] || {
      echo "error: ios-test.sh named no result bundle" >&2
      exit 1
    }
    # As ios-test.sh's gate: a file linked into two binaries counts once, at
    # the better figure.
    xcrun xccov view --report --json "$RESULTS" | python3 -c '
import json, sys
root = sys.argv[1] + "/"
best = {}
for target in json.load(sys.stdin)["targets"]:
    for f in target["files"]:
        path = f["path"]
        if not path.startswith(root + "App/BlurtiOS/"):
            continue
        rel = path[len(root):]
        if f["coveredLines"] >= best.get(rel, (0, 0))[0]:
            best[rel] = (f["coveredLines"], f["executableLines"])
for rel, (covered, total) in sorted(best.items()):
    print(f"{rel}\t{covered}\t{total}")
' "$REPO_ROOT" >"$COVERAGE"
    ;;
  *)
    echo "error: --suite wants engine or ios, got '$SUITE'" >&2
    exit 2
    ;;
esac

TARGETS="$WORK/targets.txt"
bash scripts/mutate.sh --suite "$SUITE" --print-targets >"$TARGETS"

CANDIDATES="$WORK/candidates.tsv"
: >"$CANDIDATES"
while IFS=$'\t' read -r file covered total; do
  case "$file" in *Tests/* | *Tests+* | *Tests.swift | *UITests* | *Probe/*) continue ;; esac
  [ -f "$file" ] || continue
  [ "$total" -ge "$MIN_LINES" ] || continue
  awk -v c="$covered" -v t="$total" -v min="$MIN_COVERAGE" 'BEGIN { exit !(100 * c / t >= min) }' || continue
  grep -qxF "$file" "$TARGETS" && continue
  grep -q '// mutate-not-target:' "$file" && continue
  mutants="$(bash scripts/mutate.sh --suite "$SUITE" --files "$file" --list | tail -1 | awk '{ print $1 }')"
  [ "$mutants" -ge "$MIN_MUTANTS" ] || continue
  printf '%s\t%s\t%s\n' "$file" "$(awk -v c="$covered" -v t="$total" 'BEGIN { printf "%.1f", 100 * c / t }')" "$mutants" >>"$CANDIDATES"
done <"$COVERAGE"

COUNT="$(wc -l <"$CANDIDATES" | tr -d ' ')"
REPORT="$WORK/report.md"
{
  if [ "$COUNT" -eq 0 ]; then
    echo "No $SUITE candidates: every file at >= ${MIN_COVERAGE}% line coverage with mutants to try is a target or marked \`// mutate-not-target:\`."
  else
    echo "**$COUNT $SUITE file(s)** at >= ${MIN_COVERAGE}% line coverage are not mutation targets. Add each to"
    echo "\`$([ "$SUITE" = ios ] && echo DEFAULT_IOS_TARGETS || echo DEFAULT_TARGETS)\` in \`scripts/mutate.sh\`, or mark it \`// mutate-not-target: <reason>\`."
    echo
    echo "| File | Line coverage | Mutants |"
    echo "| --- | --- | --- |"
    sort -t$'\t' -k3,3nr "$CANDIDATES" | awk -F'\t' '{ printf "| `%s` | %s%% | %s |\n", $1, $2, $3 }'
  fi
} >"$REPORT"

cat "$REPORT"
if [ -n "$OUT" ]; then cp "$REPORT" "$OUT"; fi
