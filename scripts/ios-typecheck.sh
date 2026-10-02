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
# this is the fast local loop for the App/BlurtiOS sources. The unit tests
# (`@testable import`) need the real build: scripts/ios-test.sh.
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

# The 18.0 is the deployment target App/BlurtiOS/project.yml sets.
TARGET=arm64-apple-ios18.0-macabi
COMMON=(
  -target "$TARGET" -sdk "$SDK"
  -F "$CATALYST/System/Library/Frameworks" -I "$CATALYST/usr/include"
  -swift-version 6 -parse-as-library
)

# The AssemblyAI SDK first: the engine imports it.
echo "AssemblyAI → $TARGET"
find "$REPO_ROOT/Sources/AssemblyAI" -name '*.swift' -print0 \
  | xargs -0 xcrun swiftc "${COMMON[@]}" -module-name AssemblyAI \
    -emit-module -emit-module-path "$WORK/AssemblyAI.swiftmodule"

echo "BlurtEngine → $TARGET"
find "$REPO_ROOT/Sources/BlurtEngine" -name '*.swift' -print0 \
  | xargs -0 xcrun swiftc "${COMMON[@]}" -I "$WORK" -module-name BlurtEngine \
    -emit-module -emit-module-path "$WORK/BlurtEngine.swiftmodule"

IOS="$REPO_ROOT/App/BlurtiOS"
# project.yml's SWIFT_PACKAGE_NAME, so BlurtiOSCore's `package` API resolves.
IOS_FLAGS=(
  "${COMMON[@]}" -I "$WORK" -warnings-as-errors -package-name BlurtiOS
  -Xfrontend -default-isolation -Xfrontend MainActor
)
TARGET_FLAGS=("${IOS_FLAGS[@]}" -typecheck)

# The logic both targets link: emitted, not just checked, so they import it.
# Extension-safe, since the keyboard links it (APPLICATION_EXTENSION_API_ONLY).
echo "BlurtiOSCore"
xcrun swiftc "${IOS_FLAGS[@]}" -application-extension -D DEBUG -module-name BlurtiOSCore \
  -emit-module -emit-module-path "$WORK/BlurtiOSCore.swiftmodule" "$IOS"/BlurtiOSCore/*.swift

# The component library both targets link, emitted the same way and just as
# extension-safe.
echo "BlurtDesign"
xcrun swiftc "${IOS_FLAGS[@]}" -application-extension -module-name BlurtDesign \
  -emit-module -emit-module-path "$WORK/BlurtDesign.swiftmodule" "$IOS"/BlurtDesign/*.swift

# The app also compiles the keyboard's sources, all but its entry point
# (project.yml: the theme picker and the home screen draw the real keyboard
# and orb), and CI builds Debug, so `#if DEBUG` code is checked too.
echo "BlurtiOS"
find "$IOS/BlurtKeyboard/Sources" -name '*.swift' ! -name KeyboardViewController.swift -print0 \
  | xargs -0 xcrun swiftc "${TARGET_FLAGS[@]}" -D DEBUG -module-name BlurtiOS \
    "$IOS"/BlurtiOS/Sources/*.swift

echo "BlurtKeyboard"
xcrun swiftc "${TARGET_FLAGS[@]}" -application-extension -module-name BlurtKeyboard \
  "$IOS"/BlurtKeyboard/Sources/*.swift

echo "ios-typecheck: ok"
