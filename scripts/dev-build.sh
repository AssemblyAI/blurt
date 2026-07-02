#!/usr/bin/env bash
# Build Blurt.app for local development and install it to /Applications.
#
# Unlike check.sh (which builds with codesigning DISABLED for CI), this runs a
# fully signed build so the project.yml postBuildScripts "Install to
# /Applications" step actually fires — copying the bundle to /Applications
# (or ~/Applications fallback) and re-signing it with your Developer ID.
# That stable install path is required for TCC to register Accessibility /
# Input-Monitoring / Microphone grants (DerivedData/tmp paths never do).
#
# Pipes xcodebuild through xcbeautify when available (brew install xcbeautify).
# Safe to re-run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/App/Blurt"
DERIVED_BASE="/tmp/blurt-build"

info() { printf '\033[34m▸\033[0m %s\n' "$*"; }
die() {
  printf '\033[31m✗\033[0m %s\n' "$*" >&2
  exit 1
}

command -v xcodebuild >/dev/null 2>&1 || die "missing required tool: xcodebuild"

if command -v xcbeautify >/dev/null 2>&1; then
  PRETTY=(xcbeautify --quiet)
else
  PRETTY=(cat)
  info "xcbeautify not installed; using raw output (brew install xcbeautify)"
fi

cd "$APP_DIR"

DERIVED="$DERIVED_BASE"
if [ -d "$DERIVED" ]; then
  info "Clearing DerivedData ($DERIVED)"
  if ! rm -rf "$DERIVED"; then
    DERIVED="$(mktemp -d /tmp/blurt-build.XXXXXX)"
    info "DerivedData was busy; using fresh temp dir instead ($DERIVED)"
  fi
fi

info "Building Blurt (Debug-Local) from clean and installing to /Applications"
set -o pipefail
# The Debug-Local configuration is a debug build with UITEST_HOOKS off (defined
# in project.yml), so this local build excludes the XCUITest harness and the
# leak/hotkey test seams — it's the real app, nothing test-runner-related.
# Selecting it by name (rather than overriding SWIFT_ACTIVE_COMPILATION_CONDITIONS
# on the command line) keeps the override off SwiftPM dependency targets: a
# command-line build-setting override applies to every target and replaces its
# value, silently stripping any compilation conditions the dependency packages
# set for themselves.
# The build action already builds only Blurt.app, not the BlurtUITests bundle.
xcodebuild \
  -project Blurt.xcodeproj \
  -scheme Blurt \
  -configuration Debug-Local \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  clean build | "${PRETTY[@]}"

info "Done. Launch with: open -a Blurt"
