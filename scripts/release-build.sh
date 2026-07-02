#!/usr/bin/env bash
# Build, sign, notarize, and staple a release DMG into build/release/.
# Reproducible; safe to re-run. The publish step is a separate script.
#
# Datadog (optional): if DATADOG_API_KEY is set, the build uploads the dSYM via
# datadog-ci (run through npx, so Node/npm is needed) so Release crashes
# symbolicate in Datadog. The API key is the only secret and is never stored in
# this repo; DATADOG_SITE defaults to datadoghq.com (US1). With no key the upload
# is skipped with a warning — crashes still report, just unsymbolicated — so a
# release never fails on telemetry.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/App/Blurt"
BUILD_ROOT="$REPO_ROOT/build/release"
DERIVED="$BUILD_ROOT/derived"
STAGE="$BUILD_ROOT/stage"
ENTITLEMENTS="$APP_DIR/Blurt/Blurt.entitlements"

readonly IDENTITY="640A7F5A9754400D4A0491E7A6FB30542D907806"
readonly TEAM_ID="Y54ZB9JF63"
readonly NOTARY_PROFILE="blurt-notary"
# Exact-pinned: this runs via npx on the machine holding the signing key and
# notary credentials, so "latest" would hand any compromised datadog-ci release
# arbitrary code execution mid-release. Published npm versions are immutable;
# bump this pin deliberately after reviewing the datadog-ci changelog.
readonly DATADOG_CI_VERSION="5.20.1"

SKIP_CHECKS=0
for arg in "$@"; do
  case "$arg" in
    --skip-checks) SKIP_CHECKS=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# shellcheck source=scripts/release-lib.sh
source "$REPO_ROOT/scripts/release-lib.sh"

# Submit an artifact (app zip or DMG) to Apple's notary service, wait for the
# result, and die on anything but Accepted. Writes per-artifact result + log
# plists into BUILD_ROOT (keyed by $2) so failures stay inspectable. Sets the
# global LAST_NOTARY_LOG to the log path of the most recent submission.
notarize() {
  local artifact="$1" tag="$2"
  local result_plist="$BUILD_ROOT/notary-$tag-result.plist"
  local log_json="$BUILD_ROOT/notary-$tag-log.json"
  xcrun notarytool submit "$artifact" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format plist > "$result_plist"
  local status id
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$result_plist" 2>/dev/null || echo unknown)"
  id="$(/usr/libexec/PlistBuddy -c 'Print :id' "$result_plist" 2>/dev/null || echo unknown)"
  info "notary status ($tag): $status (id $id)"
  xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" > "$log_json" 2>&1 || true
  if [ "$status" != "Accepted" ]; then
    step "Notary log ($tag)"
    cat "$log_json" 2>/dev/null || true
    die "notarization rejected for $tag (status: $status)"
  fi
  info "notary log ($tag): $log_json"
  LAST_NOTARY_LOG="$log_json"
}

if command -v xcbeautify >/dev/null 2>&1; then
  PRETTY=(xcbeautify --quiet)
else
  PRETTY=(cat)
fi

step "Preflight"
for cmd in xcodegen xcodebuild xcrun hdiutil codesign spctl create-dmg awk shasum; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing required tool: $cmd (brew install create-dmg if needed)"
done

# Datadog dSYM upload is best-effort: warn now if DATADOG_API_KEY is unset so the
# maintainer knows this build's crashes won't symbolicate, but don't block the
# release on it (unlike the Apple signing/notarization steps, which are required).
if [ -z "${DATADOG_API_KEY:-}" ]; then
  info "note: DATADOG_API_KEY unset — dSYM upload will be skipped (crashes unsymbolicated)"
fi

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' not found. Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <you@example.com> --team-id $TEAM_ID --password <app-specific-password>"

require_clean_tree "building a release artifact"

step "Read version"
VERSION="$(require_project_version "$APP_DIR/project.yml")"
info "version: $VERSION"

step "Initial summary"
info "build root:  $BUILD_ROOT"
info "identity:    $IDENTITY"
info "notary:      $NOTARY_PROFILE"

mkdir -p "$BUILD_ROOT"

if [ "$SKIP_CHECKS" -eq 0 ]; then
  step "scripts/check.sh"
  "$REPO_ROOT/scripts/check.sh"
else
  info "checks skipped (--skip-checks)"
fi

step "xcodegen"
cd "$APP_DIR"
xcodegen generate --quiet

step "xcodebuild Release"
rm -rf "$DERIVED"
xcodebuild \
  -project "$APP_DIR/Blurt.xcodeproj" \
  -scheme Blurt \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  build | "${PRETTY[@]}"

APP_BUILT="$DERIVED/Build/Products/Release/Blurt.app"
[ -d "$APP_BUILT" ] || die "expected app at $APP_BUILT — build did not produce it"
info "built: $APP_BUILT ($(du -sh "$APP_BUILT" | cut -f1))"

step "Preserve dSYM"
DSYM_SRC="$DERIVED/Build/Products/Release/Blurt.app.dSYM"
DSYM_DST="$BUILD_ROOT/Blurt-$VERSION.app.dSYM"
DSYM_ZIP="$BUILD_ROOT/Blurt-$VERSION.app.dSYM.zip"
[ -d "$DSYM_SRC" ] || die "expected dSYM at $DSYM_SRC — build did not produce it"
rm -rf "$DSYM_DST" "$DSYM_ZIP"
cp -R "$DSYM_SRC" "$DSYM_DST"
# ditto preserves the bundle layout the way macOS expects for dSYMs.
(cd "$BUILD_ROOT" && ditto -c -k --keepParent "$(basename "$DSYM_DST")" "$(basename "$DSYM_ZIP")")
info "dsym: $DSYM_DST"
info "dsym zip: $DSYM_ZIP"

step "Stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP_BUILT" "$STAGE/"
APP_STAGED="$STAGE/Blurt.app"

step "Sign nested code"
# Re-sign everything inside-out so each nested signature carries the hardened
# runtime *and* a secure timestamp the notary requires. The top-level bundle sign
# below does not re-sign already-signed nested code (we don't use --deep), so any
# component left with Xcode's timestamp-less signature would fail notarization.
NESTED_COUNT=0
# 1. Loose mach-o libraries (including any bundled inside frameworks).
while IFS= read -r -d '' f; do
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$f"
  NESTED_COUNT=$((NESTED_COUNT + 1))
done < <(find "$APP_STAGED" -type f \( -name "*.dylib" -o -name "*.so" \) -print0)
# 2. Embedded framework bundles, if any. Their mach-o binary has
# no dylib/so suffix, so step 1 misses it — sign the bundle so its signature is
# refreshed. `-depth` yields the deepest frameworks first, so a nested framework
# is signed before any framework that contains it.
while IFS= read -r -d '' fw; do
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$fw"
  NESTED_COUNT=$((NESTED_COUNT + 1))
done < <(find "$APP_STAGED" -depth -type d -name "*.framework" -print0)
info "signed $NESTED_COUNT nested component(s)"

step "Sign bundle"
codesign --force --sign "$IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  --options runtime \
  --timestamp \
  "$APP_STAGED"

step "Verify signature"
codesign --verify --strict --deep --verbose=2 "$APP_STAGED"
codesign -dvv "$APP_STAGED" 2>&1 | grep '^Timestamp=' \
  || die "no secure timestamp on bundle signature — notary would reject"
info "signature verified with secure timestamp"

# Notarize and staple the .app *before* packaging it into the DMG. Stapling the
# app bundle (not just the DMG) means it carries its own notarization ticket
# once a user drags it out to /Applications, so Gatekeeper clears it on first
# launch even offline. The DMG is notarized + stapled separately below.
step "Notarize app"
APP_ZIP="$BUILD_ROOT/Blurt-$VERSION-app.zip"
rm -f "$APP_ZIP"
ditto -c -k --keepParent "$APP_STAGED" "$APP_ZIP"
notarize "$APP_ZIP" "app"

step "Staple app"
xcrun stapler staple "$APP_STAGED"
xcrun stapler validate "$APP_STAGED"
info "app stapled + validated"

step "Create DMG"
DMG="$BUILD_ROOT/Blurt-$VERSION.dmg"
rm -f "$DMG"
create-dmg \
  --volname "Blurt $VERSION" \
  --window-size 540 380 \
  --icon-size 96 \
  --icon "Blurt.app" 140 180 \
  --app-drop-link 400 180 \
  --no-internet-enable \
  --format UDZO \
  "$DMG" \
  "$STAGE" >/dev/null

step "Verify DMG"
hdiutil verify "$DMG" >/dev/null
info "dmg verified"

step "Sign DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=1 "$DMG"
info "dmg: $DMG ($(du -sh "$DMG" | cut -f1))"

step "Notarize DMG"
notarize "$DMG" "dmg"
NOTARY_LOG="$LAST_NOTARY_LOG"

step "Staple DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
info "dmg stapled + validated"

step "Gatekeeper assessment"
# Simulates what the user's Mac will do on first launch. Catches missed-
# notarization / mis-signed bundles before they ship.
spctl --assess --type open --context context:primary-signature -v "$DMG"

step "Mount + verify DMG contents"
# Defense against silent DMG corruption: mount the image, check the bundle
# inside is signed and stapled, then eject. We pick our own mount point so
# we don't have to parse hdiutil's output (which reports /private/tmp/...
# rather than /tmp/... on macOS).
MOUNT_POINT="$(mktemp -d /tmp/blurt-dmg.XXXXXX)"
trap 'hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true; rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true' EXIT
hdiutil attach -nobrowse -noverify -mountpoint "$MOUNT_POINT" "$DMG" >/dev/null
MOUNTED_APP="$MOUNT_POINT/Blurt.app"
[ -d "$MOUNTED_APP" ] || die "mounted DMG missing Blurt.app"
xcrun stapler validate "$MOUNTED_APP" >/dev/null
codesign --verify --strict --deep "$MOUNTED_APP"
MOUNTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNTED_APP/Contents/Info.plist")"
[ "$MOUNTED_VERSION" = "$VERSION" ] || die "version mismatch inside DMG: expected $VERSION, got $MOUNTED_VERSION"
hdiutil detach "$MOUNT_POINT" >/dev/null
rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
trap - EXIT
info "dmg contents verified (Blurt.app $MOUNTED_VERSION, signed + stapled)"

step "Datadog (dSYM upload)"
# Runs after all the Apple steps so a Datadog hiccup never wastes notarization.
# Uploads the Release build's dSYM so optimized/stripped crashes symbolicate in
# Datadog. Best-effort: skipped (with a note) when DATADOG_API_KEY is unset, so a
# release never fails on telemetry. datadog-ci reads DATADOG_API_KEY and
# DATADOG_SITE from the environment; DATADOG_SITE defaults to datadoghq.com (US1).
if [ -n "${DATADOG_API_KEY:-}" ]; then
  DATADOG_SITE="${DATADOG_SITE:-datadoghq.com}" \
    npx --yes "@datadog/datadog-ci@$DATADOG_CI_VERSION" dsyms upload "$DSYM_DST"
  info "datadog: dSYM uploaded from $DSYM_DST"
else
  info "datadog: DATADOG_API_KEY unset — skipped dSYM upload"
fi

step "Provenance"
PROVENANCE="$BUILD_ROOT/build-info.txt"
{
  echo "Blurt $VERSION"
  echo "built:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "git:          $(git -C "$REPO_ROOT" rev-parse HEAD) ($(git -C "$REPO_ROOT" rev-parse --short HEAD))"
  echo "xcode:        $(xcodebuild -version | tr '\n' ' ')"
  echo "swift:        $(swift --version | head -1)"
  echo "macos sdk:    $(xcrun --sdk macosx --show-sdk-version) ($(xcrun --sdk macosx --show-sdk-build-version))"
  echo
  echo "Package.resolved sha256:"
  shasum -a 256 "$REPO_ROOT/App/Blurt/Blurt.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" 2>/dev/null \
    || shasum -a 256 "$REPO_ROOT/Package.resolved" 2>/dev/null \
    || echo "  (Package.resolved not found)"
} > "$PROVENANCE"
info "provenance: $PROVENANCE"

step "Checksums"
CHECKSUMS="$BUILD_ROOT/SHA256SUMS"
(cd "$BUILD_ROOT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$DSYM_ZIP")") > "$CHECKSUMS"
info "checksums: $CHECKSUMS"

step "Summary"
SIZE="$(du -h "$DMG" | cut -f1)"
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
cat <<EOF

  DMG:        $DMG
  Size:       $SIZE
  SHA256:     $SHA
  dSYM:       $DSYM_DST
  Checksums:  $CHECKSUMS
  Provenance: $PROVENANCE
  Notary log: $NOTARY_LOG

  Install locally to test, then publish:
    scripts/release-install.sh    # install the notarized build to /Applications
    scripts/release-publish.sh    # tag, push, publish the GitHub Release
EOF
