#!/bin/bash
# The iPhone code's quality gates, in one place — what check.sh is for the Mac.
#
#   scripts/ios-check.sh
#   BLURT_SIM_DEVICE="iPhone 17" scripts/ios-check.sh
#   scripts/ios-check.sh test probe           # only the named steps (CI's split)
#
# The same bar the engine and the Mac shell meet in check.sh, applied to
# App/BlurtiOS:
#   1. BlurtiOSTests on a simulator, warnings as errors, with BlurtiOSCore's
#      line-coverage gate (ios-test.sh; the TSan and ASan passes are its
#      BLURT_IOS_SANITIZER runs, CI's ios-sanitizers job).
#   2. The accessibility audits (BlurtiOSUITests, ios-uitest.sh):
#      `performAccessibilityAudit()` on every screen of the app, on the same
#      simulator and over the same build.
#   3. `swiftlint analyze` — every analyzer rule — over that build's compiler log,
#      as check.sh runs it over the Mac app's.
#   4. periphery over the iPhone project — unused declarations.
#   5. The probe's XCUITest bundle (BlurtiOSProbe), compiled: its own scheme,
#      run only by hand (the screenshot and keyboard-flow scripts), so nothing
#      else ever builds it — and it went uncompiled through a Swift 6 change.
# swift-format, `swiftlint lint` and the invariants already cover App/BlurtiOS
# from check.sh, which reads every tracked Swift file.
#
# The steps are test, uitest, analyze, probe and periphery; with no arguments
# all five run, which is what check.sh runs on a Mac with an iPhone simulator.
# CI runs the same steps across parallel jobs — ios-build (`test probe`),
# ios-audits (the audits, through ios-uitest.sh, on two runners split by test)
# and ios-static (`analyze periphery`) —
# since in one job they were check.yml's long pole at 40–48 minutes, the audits
# and analyze ~14 each. Run alone, `analyze` builds the tests for its log
# (ios-test.sh with BLURT_IOS_BUILD_ONLY=1) instead of reusing the test run's.
# Like check.sh, every step reports, so one failure doesn't hide the next.
#
# `swiftlint analyze` sees the files the build actually compiled. CI's build is
# from scratch, so it sees everything; a local incremental one may not —
# delete .build/ios-sim for a full local pass, as with check.sh's app build.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=scripts/release-lib.sh
source "$REPO_ROOT/scripts/release-lib.sh"
# shellcheck source=scripts/ios-lib.sh
source "$REPO_ROOT/scripts/ios-lib.sh"

STEPS="${*:-test uitest analyze probe periphery}"
for step in $STEPS; do
  case "$step" in
    test | uitest | analyze | probe | periphery) ;;
    *)
      echo "ios-check: unknown step '$step' (the steps are test, uitest, analyze, probe, periphery)" >&2
      exit 2
      ;;
  esac
done
# wants STEP → true when this run includes STEP.
wants() { case " $STEPS " in *" $1 "*) return 0 ;; *) return 1 ;; esac }

require_tools --hint='scripts/bootstrap.sh installs it' xcodegen
if wants analyze; then require_tools --hint='scripts/bootstrap.sh installs it' swiftlint; fi
if wants periphery; then require_tools --hint='scripts/bootstrap.sh installs it' periphery; fi

FAILED=()
BUILD_LOG="$(mktemp -t blurt-ios-build)"
APP_LOG="$(mktemp -t blurt-ios-build-app)"
trap 'rm -f "$BUILD_LOG" "$APP_LOG"' EXIT

if wants test; then
  echo "==> ios-test (BlurtiOSTests + BlurtiOSCore coverage gate)"
  BLURT_IOS_BUILD_LOG="$BUILD_LOG" "$REPO_ROOT/scripts/ios-test.sh" || FAILED+=("ios-test")
fi

if wants uitest; then
  echo "==> ios-uitest (BlurtiOSUITests: accessibility audits)"
  "$REPO_ROOT/scripts/ios-uitest.sh" || FAILED+=("ios-uitest")
fi

if wants analyze; then
  if ! wants test; then
    echo "==> build-for-testing (BlurtiOS, for swiftlint analyze's compiler log)"
    BLURT_IOS_BUILD_ONLY=1 BLURT_IOS_BUILD_LOG="$BUILD_LOG" "$REPO_ROOT/scripts/ios-test.sh" \
      || FAILED+=("build-for-testing (BlurtiOS)")
  fi
  echo "==> swiftlint analyze (App/BlurtiOS)"
  if [ -s "$BUILD_LOG" ]; then
    # The iPhone modules' compile commands only. The build also compiles the
    # engine — for iOS, where its `#if os(macOS)` files are inactive and
    # SourceKit can't resolve them — and check.sh analyzes the engine from the
    # Mac build, where they are live; and KeyboardKit's one source target
    # (KeyboardKitDependencies, third-party, outside every path .swiftlint.yml
    # includes).
    grep -vE -- '-module-name (BlurtEngine|KeyboardKitDependencies) ' "$BUILD_LOG" >"$APP_LOG" || true
    "$REPO_ROOT/scripts/swiftlint-analyze.sh" "$APP_LOG" App/BlurtiOS || FAILED+=("swiftlint analyze")
  else
    echo "error: no build log to analyze — the build above did not run" >&2
    FAILED+=("swiftlint analyze")
  fi
fi

if wants probe; then
  echo "==> build-for-testing (BlurtiOSProbe)"
  # The tests' destination, flags and derived data, so the build above is
  # reused and only the probe's own files compile (a generic destination would
  # rebuild everything for a second architecture).
  UDID="$(ios_pick_device "${BLURT_SIM_DEVICE:-$IOS_DEFAULT_DEVICE}" | cut -f1)"
  if [ -n "$UDID" ]; then
    xcodebuild build-for-testing -project App/BlurtiOS/BlurtiOS.xcodeproj -scheme BlurtiOSProbe \
      -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$IOS_DERIVED" \
      "${IOS_SIM_SIGNING[@]}" -enableCodeCoverage YES -quiet || FAILED+=("build-for-testing (BlurtiOSProbe)")
  else
    echo "error: no iPhone simulator to build the probe for" >&2
    FAILED+=("build-for-testing (BlurtiOSProbe)")
  fi
fi

if wants periphery; then
  echo "==> periphery (App/BlurtiOS)"
  # Its own build, for a device: the tests' simulator index would report the
  # phone's capture path (WindowedAudioSource) as unused, since the simulator
  # builds SimulatorAudioSource in its place. `--retain-public`: the engine's
  # public API is used by the Mac app this scan can't see, and the engine's own
  # findings are excluded from the report, so only the iPhone code's dead
  # declarations are reported. BlurtiOSCore's API is `package`, not public, so
  # it is still scanned.
  #
  # `--clean-build`: periphery keeps its DerivedData between runs
  # (~/Library/Caches/com.github.peripheryapp), and an index unit for a file
  # that no longer compiles to the same output is never replaced — it outlives
  # the build that wrote it. A scan then reads a declaration from that old build
  # with none of today's references and reports live code as unused (after
  # #315, `TermField` and its `Caret`, at the line numbers of the file before
  # it). Clearing it costs a local run its incremental build; CI starts clean
  # anyway.
  periphery scan --project App/BlurtiOS/BlurtiOS.xcodeproj --schemes BlurtiOS \
    --retain-public --retain-unused-protocol-func-params --clean-build \
    --report-exclude 'Sources/**' --strict --quiet || FAILED+=("periphery")
fi

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "error: ${#FAILED[@]} iPhone check(s) failed:" >&2
  printf '         %s\n' "${FAILED[@]}" >&2
  exit 1
fi
echo "==> ios-check: ok"
