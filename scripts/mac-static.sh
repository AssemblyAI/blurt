#!/bin/bash
# The Mac app's build and the two checks that need it: `swiftlint analyze` over
# its compiler log, and periphery.
#
#   scripts/mac-static.sh                       # build, analyze, periphery
#   scripts/mac-static.sh build                 # just the build
#   BLURT_MAC_BUILD_LOG=/tmp/log scripts/mac-static.sh build   # keep the log there
#
# The steps are build, analyze and periphery; with no arguments all three run.
# check.sh runs `build` as its app build, then `analyze` and `periphery` over
# that build's log. CI's `macos` job stops after the build (BLURT_STATIC_CHECKS=0)
# and check.yml's `mac-static` job runs all three on a runner of its own: on one
# runner they were ~10 of `macos`'s ~21 minutes, and they need nothing but the
# app build.
#
# The log is BLURT_MAC_BUILD_LOG, so a later `analyze` can read an earlier
# `build`'s; unset, a temporary file serves one invocation. `analyze` without a
# build log to read fails rather than analyzing nothing. Like check.sh, the two
# checks each report, so one failing doesn't hide the other; a failed build
# stops the run, since neither has anything to read without it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=scripts/release-lib.sh
source "$REPO_ROOT/scripts/release-lib.sh"

STEPS="${*:-build analyze periphery}"
for step in $STEPS; do
  case "$step" in
    build | analyze | periphery) ;;
    *)
      echo "mac-static: unknown step '$step' (the steps are build, analyze, periphery)" >&2
      exit 2
      ;;
  esac
done
# wants STEP → true when this run includes STEP.
wants() { case " $STEPS " in *" $1 "*) return 0 ;; *) return 1 ;; esac }

if wants analyze; then require_tools --hint='scripts/bootstrap.sh installs it' swiftlint; fi
if wants periphery; then require_tools --hint='scripts/bootstrap.sh installs it' periphery; fi

LOG="${BLURT_MAC_BUILD_LOG:-}"
if [ -z "$LOG" ]; then
  LOG="$(mktemp "${TMPDIR:-/tmp}/blurt-build.XXXXXX")"
  trap 'rm -f "$LOG"' EXIT
fi

if wants build; then
  echo "==> xcodebuild build (Blurt)"
  # Skip codesigning for the health-check build: the Developer ID cert only
  # lives on the maintainer's machine. The postBuildScripts "Install to
  # /Applications" step also bails out when CODE_SIGNING_ALLOWED=NO.
  # Warnings-as-errors for the app target is set in project.yml
  # (SWIFT_TREAT_WARNINGS_AS_ERRORS), scoped there to avoid colliding with the
  # -suppress-warnings Xcode applies to SPM dependency packages.
  # The raw log is tee'd to $LOG so `analyze` can read the compiler invocations
  # for its analyzer rules. This build compiles both the app and the engine
  # package, so the log covers both.
  pretty_xcodebuild
  (cd "$REPO_ROOT/App/Blurt" && xcodebuild \
    -project Blurt.xcodeproj \
    -scheme Blurt \
    -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | tee "$LOG" | "${PRETTY[@]}")
fi

FAILED=()

if wants analyze; then
  echo "==> swiftlint analyze"
  # Every analyzer rule .swiftlint.yml lists — unused imports (the one dead-code
  # gap periphery doesn't cover), captured variables, untyped array inits;
  # unused declarations are periphery's. False positives on AVFoundation/OSLog
  # imports are suppressed via always_keep_imports in .swiftlint.yml. Split
  # across processes by swiftlint-analyze.sh, which fails when the log compiles
  # none of the files.
  if [ -s "$LOG" ]; then
    "$REPO_ROOT/scripts/swiftlint-analyze.sh" "$LOG" || FAILED+=("swiftlint analyze")
  else
    echo "error: no build log to analyze — run the build step first (BLURT_MAC_BUILD_LOG)" >&2
    FAILED+=("swiftlint analyze")
  fi
fi

if wants periphery; then
  echo "==> periphery"
  # --strict promotes any unused-code finding to a non-zero exit. Periphery does
  # its own xcodebuild + index — separate from the build above because reusing
  # DerivedData reliably across machines is fragile.
  #
  # `--clean-build`, as ios-check.sh's iPhone scan has: periphery keeps its
  # DerivedData between runs, and an index unit for a file that no longer
  # compiles to the same output is never replaced. After a file is renamed or
  # split, a scan reads the old file's declarations with none of today's
  # references and reports live code as unused. CI starts clean anyway.
  periphery scan --strict --quiet --clean-build || FAILED+=("periphery")
fi

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "error: ${#FAILED[@]} Mac check(s) failed:" >&2
  printf '         %s\n' "${FAILED[@]}" >&2
  exit 1
fi
echo "==> mac-static: ok"
