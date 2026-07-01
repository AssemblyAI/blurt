#!/bin/bash
# Run the XCUITest integration suite (BlurtUITests) against a Debug build of the
# Blurt app launched in UI-test mode (the `-BlurtUITest` harness in
# UITestSupport.swift). macOS-only; needs Xcode. See App/Blurt/BlurtUITests/.
#
# check.sh runs this same suite as part of the required gate; this script is the
# standalone entry point (faster to iterate on, no engine/lint steps first).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/App/Blurt"

export OS_ACTIVITY_MODE=disable

if command -v xcbeautify >/dev/null 2>&1; then
  PRETTY=(xcbeautify --quiet)
else
  PRETTY=(cat)
  echo "note: xcbeautify not installed; using raw output (brew install xcbeautify)"
fi

echo "==> xcodebuild test (BlurtUITests)"
cd "$APP_DIR"
set -o pipefail
# Ad-hoc signing (identity "-", signing ALLOWED) — NOT disabled. A UI-test
# runner must carry a real code signature: the linker-only ad-hoc that
# CODE_SIGNING_ALLOWED=NO leaves behind omits the `get-task-allow` entitlement
# the test infrastructure needs to attach, so the runner is SIGKILLed before it
# connects. Ad-hoc signing embeds it (and the app under test only ever runs from
# DerivedData). The Developer ID cert still isn't required: the app target's
# "Install to /Applications" post-build script skips itself under the "-"
# identity (see project.yml), so nothing tries to sign with it.
# -testPlan Blurt: run under Blurt.xctestplan, which retries a failing UI test
# (up to 3 attempts) so a flake isn't an immediate red, and keeps screenshots +
# attachments on the .xcresult for debugging a genuine failure on CI.
xcodebuild \
  -project Blurt.xcodeproj \
  -scheme Blurt \
  -testPlan Blurt \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlurtUITests \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  test | "${PRETTY[@]}"

echo "==> ok"
