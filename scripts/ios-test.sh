#!/bin/bash
# Run the iPhone app's unit tests (BlurtiOSTests) on a simulator.
#
#   scripts/ios-test.sh                          # tests + the line-coverage gate
#   BLURT_IOS_SANITIZER=thread scripts/ios-test.sh   # tests under ThreadSanitizer
#   BLURT_IOS_SANITIZER=address scripts/ios-test.sh  # tests under AddressSanitizer
#   BLURT_SIM_DEVICE="iPhone 17" scripts/ios-test.sh
#
# Hosted by the app, signed ad hoc, on the named simulator or whichever iPhone
# this Mac (or CI runner) has. The engine's own tests are `swift test`
# (scripts/check.sh); these cover the iPhone code's pure logic — the App Group
# contract, the keyboard's rules, term packs. The per-test log is in the
# result bundle the last line names. A failure never triggers xcodebuild's
# sysdiagnose collection (`-collect-test-diagnostics never`): that step takes
# ten minutes on this simulator and the result bundle already says what failed.
#
# The same gates the engine's suite runs under in check.sh: warnings are errors
# (project.yml), a plain run must hold BlurtiOSCore's line coverage at or
# above MIN_IOS_COVERAGE, and CI runs the suite again under each sanitizer. A
# sanitizer run skips the coverage gate — the instrumented build is a second
# pass over the same tests, not a second measurement — and builds into its own
# derived-data directory, so it never reuses (or poisons) the plain build.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/release-lib.sh
source "$REPO_ROOT/scripts/release-lib.sh"
# shellcheck source=scripts/ios-lib.sh
source "$REPO_ROOT/scripts/ios-lib.sh"

# BlurtiOSCore's line-coverage floor (percent) — the engine's own bar
# (check.sh's MIN_COVERAGE). The core is the iPhone code's logic, apart from
# its UI the way BlurtEngine is apart from the Mac shell; the views in the app
# and the keyboard are measured by eye and by the probe's screenshot flows, as
# the Mac shell is by its XCUITest suite, not by this number. Raise it as
# coverage grows; never lower it to land a change.
MIN_IOS_COVERAGE=88
# Every core file counts: nothing in it needs a device. A file that ever does
# gets an exclusion here, with its reason, the way check.sh lists the engine's.
IOS_CORE="App/BlurtiOS/BlurtiOSCore/"

# A plain run measures coverage; a sanitizer run instruments for its sanitizer
# instead. Exactly one, so the array is never empty.
SANITIZER="${BLURT_IOS_SANITIZER:-}"
case "$SANITIZER" in
  "") TEST_FLAGS=(-enableCodeCoverage YES) ;;
  thread) TEST_FLAGS=(-enableThreadSanitizer YES) ;;
  address) TEST_FLAGS=(-enableAddressSanitizer YES) ;;
  *)
    echo "ios-test: BLURT_IOS_SANITIZER must be thread or address, not '$SANITIZER'" >&2
    exit 1
    ;;
esac
DERIVED="$IOS_DERIVED${SANITIZER:+-$SANITIZER}"

PICKED="$(ios_pick_device "${BLURT_SIM_DEVICE:-iPhone 18 Pro}")"
if [ -z "$PICKED" ]; then
  echo "ios-test: no iPhone simulator available (xcrun simctl list devices)" >&2
  exit 1
fi
UDID="${PICKED%%	*}"
echo "testing on ${PICKED#*	}${SANITIZER:+ under the $SANITIZER sanitizer}"
ios_wait_booted "$UDID"

(cd "$REPO_ROOT/App/BlurtiOS" && xcodegen generate --quiet)
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS="$DERIVED/BlurtiOSTests-$STAMP.xcresult"
# The whole xcodebuild log, kept rather than `-quiet`ed away: ios-check.sh feeds
# its compiler invocations to `swiftlint analyze`. The terminal gets it through
# xcbeautify, as check.sh's app build does; the log path is printed at the end.
BUILD_LOG="${BLURT_IOS_BUILD_LOG:-$DERIVED/BlurtiOSTests-$STAMP.log}"
mkdir -p "$(dirname "$BUILD_LOG")"
pretty_xcodebuild
# Serial for the reason project.yml's scheme gives (the tests share one global
# App Group override); said here too so no test plan or default can undo it.
xcodebuild test -project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" -scheme BlurtiOS \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" \
  -resultBundlePath "$RESULTS" "${IOS_SIM_SIGNING[@]}" "${TEST_FLAGS[@]}" \
  -parallel-testing-enabled NO -collect-test-diagnostics never 2>&1 \
  | tee "$BUILD_LOG" | "${PRETTY[@]}"
xcrun xcresulttool get test-results summary --path "$RESULTS" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("ios-test:", d.get("passedTests", "?"), "passed,", d.get("failedTests", "?"), "failed,", d.get("skippedTests", 0), "skipped")
' || true
echo "results: $RESULTS"
echo "build log: $BUILD_LOG"

[ -n "$SANITIZER" ] && exit 0

echo "==> coverage gate (>= ${MIN_IOS_COVERAGE}% BlurtiOSCore lines)"
# The core is static, linked into the app and the keyboard both, so its files
# can appear under either binary: each is counted once, at the better figure
# (the tests run in the app's process; the keyboard's copy is never reached).
COVERAGE="$(xcrun xccov view --report --json "$RESULTS" | python3 -c '
import json, sys
root, core = sys.argv[1], sys.argv[2]
files = {}
for target in json.load(sys.stdin)["targets"]:
    for f in target["files"]:
        path = f["path"]
        rel = path[len(root) + 1:] if path.startswith(root + "/") else path
        if not rel.startswith(core):
            continue
        best = files.get(rel, (0, 0))
        if f["coveredLines"] >= best[0]:
            files[rel] = (f["coveredLines"], f["executableLines"])
if not files:
    sys.exit("no BlurtiOSCore sources in the coverage report")
covered = sum(c for c, _ in files.values())
total = sum(t for _, t in files.values())
print(round(100 * covered / total, 2))
' "$REPO_ROOT" "$IOS_CORE")"
echo "BlurtiOSCore line coverage: ${COVERAGE}%"
if ! awk -v c="$COVERAGE" -v min="$MIN_IOS_COVERAGE" 'BEGIN{ exit (c+0 < min+0) }'; then
  echo "error: coverage ${COVERAGE}% is below the ${MIN_IOS_COVERAGE}% floor" >&2
  exit 1
fi
