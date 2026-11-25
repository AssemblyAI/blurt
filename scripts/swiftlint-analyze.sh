#!/bin/bash
# `swiftlint analyze` over a compiler log, split across several processes.
#
#   scripts/swiftlint-analyze.sh COMPILER_LOG [PATH...]
#   BLURT_ANALYZE_JOBS=1 scripts/swiftlint-analyze.sh COMPILER_LOG   # one process, as before
#
# The analyzer rules .swiftlint.yml lists, with --strict, over the tracked Swift
# files under each PATH (default: .swiftlint.yml's `included`), reading their
# compile commands from COMPILER_LOG — the same files and rules a single
# `swiftlint analyze --compiler-log-path COMPILER_LOG [PATH...]` reads.
#
# Why sharded: SwiftLint runs analyze one file at a time on Swift 5.6 and later
# (LintableFilesVisitor: concurrent SourceKit requests in one process got ~100×
# dearer), so a single process uses one core and took 8.5 minutes over the Mac
# build and 13.6 over the iPhone one on CI's three-core runner. Separate
# processes each have their own SourceKit, so the files are dealt round-robin
# into BLURT_ANALYZE_JOBS lists (default: the core count, at most 4 — each
# process holds a SourceKit's memory) and the lists run side by side. Every
# process reports; the script fails if any one does.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [ "$#" -lt 1 ] || [ ! -s "$1" ]; then
  echo "usage: scripts/swiftlint-analyze.sh COMPILER_LOG [PATH...] (the log must exist and be non-empty)" >&2
  exit 2
fi
LOG="$1"
shift

if [ "$#" -eq 0 ]; then
  # .swiftlint.yml's `included:` list — the paths a bare `swiftlint analyze` reads.
  # Read here rather than restated, so the two can't drift. Split on purpose:
  # one path per word, and none of them holds a space.
  # shellcheck disable=SC2046
  set -- $(awk '/^included:/ { on = 1; next } on && /^  - / { print $2; next } { on = 0 }' .swiftlint.yml)
  [ "$#" -gt 0 ] || {
    echo "swiftlint-analyze: no paths given and no 'included:' list in .swiftlint.yml" >&2
    exit 2
  }
fi

JOBS="${BLURT_ANALYZE_JOBS:-}"
if [ -z "$JOBS" ]; then
  JOBS="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  if [ "$JOBS" -gt 4 ]; then JOBS=4; fi
fi
case "$JOBS" in
  '' | *[!0-9]* | 0)
    echo "swiftlint-analyze: BLURT_ANALYZE_JOBS must be a positive integer, not '$JOBS'" >&2
    exit 2
    ;;
esac

SHARDS="$(mktemp -d "${TMPDIR:-/tmp}/blurt-analyze.XXXXXX")"
trap 'rm -rf "$SHARDS"' EXIT

# Absolute paths, and only those the log compiles. SwiftLint looks a file's
# compile command up by its URL, keyed on the absolute paths in the log, and
# skips any file it finds none for without a word — so a relative path, or a
# file the build never compiled, is silently not analyzed. (The first version
# of this script passed relative paths, and both platforms' analyze passed in
# a second having read nothing.) Selecting the files the log names is the same
# test SwiftLint applies, done here where an empty result can fail loudly.
git ls-files -- "$@" | { grep '\.swift$' || true; } | sed "s|^|$REPO_ROOT/|" | sort -u >"$SHARDS/candidates"
tr ' ' '\n' <"$LOG" | { grep '\.swift$' || true; } | sort -u >"$SHARDS/compiled"
comm -12 "$SHARDS/candidates" "$SHARDS/compiled" >"$SHARDS/files"

CANDIDATES="$(wc -l <"$SHARDS/candidates" | tr -d ' ')"
FILES="$(wc -l <"$SHARDS/files" | tr -d ' ')"
if [ "$CANDIDATES" -eq 0 ]; then
  echo "swiftlint-analyze: no tracked Swift files under: $*" >&2
  exit 2
fi
if [ "$FILES" -eq 0 ]; then
  echo "swiftlint-analyze: $LOG compiles none of the $CANDIDATES Swift files under: $*" >&2
  echo "  (not a build log, or its paths aren't under $REPO_ROOT) — nothing would be analyzed" >&2
  exit 2
fi
awk -v n="$JOBS" -v dir="$SHARDS" '{ print > (dir "/shard." (NR % n)) }' "$SHARDS/files"
echo "swiftlint analyze: $FILES of $CANDIDATES files (the rest aren't in this build) in $(find "$SHARDS" -name 'shard.*' | wc -l | tr -d ' ') processes"

PIDS=()
for shard in "$SHARDS"/shard.*; do
  # Tracked paths never hold a newline, so one per line is safe to hand to
  # xargs -0 once translated. --force-exclude keeps .swiftlint.yml's `excluded`
  # in force for paths named on the command line, as it is for a directory walk.
  tr '\n' '\0' <"$shard" \
    | xargs -0 swiftlint analyze --strict --quiet --force-exclude --compiler-log-path "$LOG" &
  PIDS+=("$!")
done

STATUS=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || STATUS=1
done
exit "$STATUS"
