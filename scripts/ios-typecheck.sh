#!/bin/bash
# Typecheck the iPhone app and its keyboard on a Mac that has no iOS SDK.
#
# The Command Line Tools ship no iOS SDK, but their macOS SDK carries the Mac
# Catalyst frameworks (UIKit, SwiftUI and AVFAudio built for iOS-on-Mac). That
# is the closest stand-in for iOS an Xcode-less Mac has: `os(iOS)` is true, the
# engine builds in its iOS shape, and the Swift 6 isolation errors the iPhone
# targets can hit surface here with the same wording CI's `ios-build` job
# prints. Each target is checked with the flags its project.yml sets — warnings
# are errors, and every declaration defaults to the main actor.
#
# What it cannot see: APIs that differ between Catalyst and iOS proper, code
# signing, linking, and the generated project itself. CI stays the authority;
# this is the fast local loop for the App/BlurtiOS sources.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --show-sdk-path)"
CATALYST="$SDK/System/iOSSupport"
if [ ! -d "$CATALYST/System/Library/Frameworks/UIKit.framework" ]; then
  echo "ios-typecheck: no Mac Catalyst frameworks under $SDK" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TARGET=arm64-apple-ios18.0-macabi
COMMON=(
  -target "$TARGET" -sdk "$SDK"
  -F "$CATALYST/System/Library/Frameworks" -I "$CATALYST/usr/include"
  -swift-version 6 -parse-as-library
)

echo "BlurtEngine → $TARGET"
find "$REPO_ROOT/Sources/BlurtEngine" -name '*.swift' -print0 \
  | xargs -0 xcrun swiftc "${COMMON[@]}" -module-name BlurtEngine \
    -emit-module -emit-module-path "$WORK/BlurtEngine.swiftmodule"

IOS="$REPO_ROOT/App/BlurtiOS"
TARGET_FLAGS=(
  "${COMMON[@]}" -typecheck -I "$WORK" -warnings-as-errors
  -Xfrontend -default-isolation -Xfrontend MainActor
)

echo "BlurtiOS"
xcrun swiftc "${TARGET_FLAGS[@]}" -module-name BlurtiOS \
  "$IOS"/BlurtiOS/Sources/*.swift "$IOS"/Shared/*.swift

echo "BlurtKeyboard"
xcrun swiftc "${TARGET_FLAGS[@]}" -application-extension -module-name BlurtKeyboard \
  "$IOS"/BlurtKeyboard/Sources/*.swift "$IOS"/Shared/*.swift

echo "ios-typecheck: ok"
