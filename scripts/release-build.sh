#!/usr/bin/env bash
# Build, sign, notarize, and staple a release DMG into build/release/.
# Reproducible; safe to re-run. The publish step is a separate script.
#
# Sentry (required): `sentry-cli` must be installed and authenticated — either a
# `sentry-cli login` session or a SENTRY_AUTH_TOKEN in the environment. The auth
# token is the ONLY secret and is never stored in this repo. The org slug +
# project ID below are NOT secrets (the project ID is the same one in the public
# DSN committed in AppDelegate.swift — a DSN ships inside the app binary by
# design), so they're hard-coded here. The build uploads the dSYM (so Release
# crashes symbolicate)
# and creates + finalizes the matching Sentry release (so release-health adoption
# / crash-free-by-release charts populate). Unauthenticated or no sentry-cli →
# preflight fails before building.

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

# Sentry org slug + project ID (not secrets — see the header note). Exported so
# sentry-cli picks them up without per-command --org/--project flags. The org
# must be the *slug*, not the numeric ID from the DSN: sentry-cli matches the
# slug embedded in the auth token, and a numeric org ID makes it warn and fall
# back to the token's org. (The org is inferable from the token, but pinning it
# keeps the target explicit.)
export SENTRY_ORG="alex-kroman"
export SENTRY_PROJECT="4511634026004480"

SKIP_CHECKS=0
for arg in "$@"; do
  case "$arg" in
    --skip-checks) SKIP_CHECKS=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

info()  { printf '\033[34m▸\033[0m %s\n' "$*"; }
step()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die()   { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

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
for cmd in xcodegen xcodebuild xcrun hdiutil codesign spctl create-dmg awk shasum sentry-cli; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing required tool: $cmd (brew install create-dmg / getsentry/tools/sentry-cli if needed)"
done

# Sentry auth must be present — the dSYM upload + release creation later depend
# on it, so fail now rather than after the expensive build/notarization. We don't
# dictate *how* it's supplied (a `sentry-cli login` session or a SENTRY_AUTH_TOKEN
# in the environment both work), only that sentry-cli is authenticated.
if sentry-cli info 2>&1 | grep -q "Method: Unauthorized"; then
  die "sentry-cli not authenticated — run 'sentry-cli login' (or export SENTRY_AUTH_TOKEN)"
fi

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' not found. Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <you@example.com> --team-id $TEAM_ID --password <app-specific-password>"

[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] \
  || die "working tree dirty — commit or stash before building a release artifact"

step "Read version"
VERSION="$(awk '/CFBundleShortVersionString:/ {gsub(/"/,"",$2); print $2; exit}' "$APP_DIR/project.yml")"
[ -n "$VERSION" ] || die "could not parse CFBundleShortVersionString from $APP_DIR/project.yml"
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
# 2. Embedded framework bundles (e.g. Sentry.framework). Their mach-o binary has
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

step "Sentry (dSYM + release)"
# Runs after all the Apple steps so a Sentry hiccup never wastes notarization.
# Auth + sentry-cli are validated in preflight and org/project are exported
# above, so the commands here need no credentials or --org/--project flags.
# The Sentry release name must match what the in-app SDK auto-tags events with:
# {CFBundleIdentifier}@{CFBundleShortVersionString}+{CFBundleVersion}.
BUILD_NUM="$(awk '/CFBundleVersion:/ {gsub(/"/,"",$2); print $2; exit}' "$APP_DIR/project.yml")"
[ -n "$BUILD_NUM" ] || die "could not parse CFBundleVersion from $APP_DIR/project.yml"
SENTRY_RELEASE="dev.alex.blurt@${VERSION}+${BUILD_NUM}"
info "sentry release: $SENTRY_RELEASE"

# Symbolicates crashes from the optimized/stripped Release build.
sentry-cli debug-files upload "$DSYM_DST"

# Create + finalize so adoption / crash-free-by-release / regression charts
# light up. Commit association is best-effort — it needs either a Sentry repo
# integration (--auto) or local git history (--local).
sentry-cli releases new "$SENTRY_RELEASE"
sentry-cli releases set-commits "$SENTRY_RELEASE" --auto \
  || sentry-cli releases set-commits "$SENTRY_RELEASE" --local \
  || info "commit association skipped (no repo integration / git history)"
sentry-cli releases finalize "$SENTRY_RELEASE"
info "sentry: dSYM uploaded + release $SENTRY_RELEASE finalized"

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
