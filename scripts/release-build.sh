#!/usr/bin/env bash
# Build, sign, notarize, and staple a release DMG into build/release/.
# Reproducible; safe to re-run. The publish step is a separate script.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/App/Blurt"
BUILD_ROOT="$REPO_ROOT/build/release"
DERIVED="$BUILD_ROOT/derived"
STAGE="$BUILD_ROOT/stage"
ENTITLEMENTS="$APP_DIR/Blurt/Blurt.entitlements"

readonly IDENTITY="640A7F5A9754400D4A0491E7A6FB30542D907806"
# SHA-256 fingerprint of the same Developer ID leaf cert as IDENTITY (which is
# its SHA-1 identity hash, the only format `codesign --sign` accepts). The
# signer-pin verifies produced artifacts against this stronger digest.
readonly IDENTITY_SHA256="FB3F95250468655C8329314E104B96E3C75443AEB1A349A43D0C9AABF0B255B5"
readonly TEAM_ID="Y54ZB9JF63"
readonly NOTARY_PROFILE="blurt-notary"

SKIP_CHECKS=0
SKIP_SMOKE=0
for arg in "$@"; do
  case "$arg" in
    --skip-checks) SKIP_CHECKS=1 ;;
    --skip-smoke) SKIP_SMOKE=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# shellcheck source=scripts/release-lib.sh
source "$REPO_ROOT/scripts/release-lib.sh"

# --- Dedicated signing keychain (normally locked) -----------------------------
# The Developer ID signing key lives in its own keychain that stays LOCKED at
# rest instead of in the login keychain. Unlock it for the duration of the build
# and re-lock on exit (see the EXIT trap wired up after the identity check). If
# that keychain isn't present — a machine that still keeps the key in login, or
# mid-migration — fall through to whatever's already on the search list so
# releases keep working.
SIGNING_KEYCHAIN="${BLURT_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/blurt-signing.keychain-db}"
SIGNING_KEYCHAIN_UNLOCKED=0

# Resolve the keychain password: env (from 1Password / a CI secret) first, then
# an interactive prompt. Deliberately NOT read from the login keychain — the
# whole point of the dedicated keychain is that its unlock secret does not sit in
# login (where any process running as you can read it while you're logged in).
# Locally, supply it from 1Password, e.g.:
#   BLURT_SIGNING_KEYCHAIN_PASSWORD="$(op read 'op://<vault>/Blurt signing keychain/password')" \
#     scripts/release.sh
signing_keychain_password() {
  if [ -n "${BLURT_SIGNING_KEYCHAIN_PASSWORD:-}" ]; then
    printf '%s' "$BLURT_SIGNING_KEYCHAIN_PASSWORD"
    return 0
  fi
  local pw
  read -rsp "Password for signing keychain ($SIGNING_KEYCHAIN): " pw </dev/tty \
    || die "no signing keychain password provided (set BLURT_SIGNING_KEYCHAIN_PASSWORD)"
  printf '\n' >&2
  printf '%s' "$pw"
}

unlock_signing_keychain() {
  if [ ! -f "$SIGNING_KEYCHAIN" ]; then
    info "no dedicated signing keychain at $SIGNING_KEYCHAIN — using existing search list"
    return 0
  fi
  # Ensure it's on the user search list without dropping the existing entries
  # (a bare `list-keychains -s <one>` would replace login + System).
  local -a search=()
  local k present=0
  while IFS= read -r k; do
    k="${k#"${k%%[![:space:]]*}"}" # ltrim
    k="${k%\"}"
    k="${k#\"}" # strip surrounding quotes
    [ -n "$k" ] && search+=("$k")
  done < <(security list-keychains -d user)
  for k in "${search[@]}"; do [ "$k" = "$SIGNING_KEYCHAIN" ] && present=1; done
  [ "$present" -eq 1 ] || security list-keychains -d user -s "$SIGNING_KEYCHAIN" "${search[@]}"

  local pw
  pw="$(signing_keychain_password)"
  security unlock-keychain -p "$pw" "$SIGNING_KEYCHAIN" \
    || die "failed to unlock signing keychain $SIGNING_KEYCHAIN"
  SIGNING_KEYCHAIN_UNLOCKED=1
  info "unlocked dedicated signing keychain: $SIGNING_KEYCHAIN"
}

lock_signing_keychain() {
  [ "$SIGNING_KEYCHAIN_UNLOCKED" -eq 1 ] || return 0
  security lock-keychain "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
  SIGNING_KEYCHAIN_UNLOCKED=0
}

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

# Best-effort launch check: Blurt is a GUI app (wants Accessibility/mic, shows
# an overlay) so it can't run headless — this only catches a build that dies on
# launch. The human release-install.sh step remains the real functional gate.
# NOTE: pkill below also terminates any Blurt the maintainer had running.
crash_list() {
  local dir="$HOME/Library/Logs/DiagnosticReports"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -name 'Blurt*' -print 2>/dev/null | sort || true
}
smoke_launch() {
  local app="$1" before after new
  # Quit any Blurt the maintainer already has running so the checks below
  # reflect the freshly-built staged instance — `open` would otherwise just
  # reactivate the existing one, and `pgrep -x Blurt` can't tell them apart.
  if pgrep -x Blurt >/dev/null; then
    info "smoke test: quitting an already-running Blurt first"
    osascript -e 'tell application "Blurt" to quit' >/dev/null 2>&1 || true
    pkill -x Blurt >/dev/null 2>&1 || true
    sleep 1
  fi
  before="$(crash_list)"
  open -gn "$app" || die "smoke test: could not launch $app"
  sleep 2
  if ! pgrep -x Blurt >/dev/null; then
    after="$(crash_list)"
    new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
    die "smoke test: Blurt exited within 2s of launch${new:+ (new crash report: $new)}"
  fi
  sleep 3
  after="$(crash_list)"
  new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
  osascript -e 'tell application "Blurt" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x Blurt >/dev/null 2>&1 || true
  [ -z "$new" ] || die "smoke test: new crash report(s) after launch: $new"
  info "smoke test: launched, stayed up 5s, no crash report"
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

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' not found. Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <you@example.com> --team-id $TEAM_ID --password <app-specific-password>"

unlock_signing_keychain
# Re-lock the dedicated signing keychain no matter how we exit (success, die, or
# a mid-build failure). Lives here rather than in a dedicated cleanup because the
# only other EXIT trap (the DMG mount, below) is set up much later.
trap lock_signing_keychain EXIT

identity_listed "$IDENTITY" <<<"$(security find-identity -v -p codesigning)" \
  || die "Developer ID identity $IDENTITY not in keychain (check: security find-identity -v -p codesigning). Wrong Mac, or the signing key is missing."

require_clean_tree "building a release artifact"

step "Verify pinned dependencies"
# The app currently carries no external SPM packages (only the local
# BlurtEngine), so Xcode generates no Package.resolved. If a dependency is ever
# added, this gate ensures its pins are committed and reviewed rather than
# floating. Absent a Package.resolved there is nothing to pin, so pass.
RESOLVED="$APP_DIR/Blurt.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if [ -f "$RESOLVED" ]; then
  git -C "$REPO_ROOT" ls-files --error-unmatch "$RESOLVED" >/dev/null 2>&1 \
    || die "Package.resolved exists but is not tracked by git — dependency pins would be unreviewed"
  info "dependency pins tracked: $RESOLVED"
else
  info "no external SPM dependencies (no Package.resolved) — nothing to pin"
fi

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
verify_signer "$APP_STAGED" "$IDENTITY_SHA256" "$TEAM_ID"
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

if [ "$SKIP_SMOKE" -eq 0 ]; then
  step "Launch smoke test"
  smoke_launch "$APP_STAGED"
else
  info "smoke test skipped (--skip-smoke)"
fi

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
verify_signer "$DMG" "$IDENTITY_SHA256" "$TEAM_ID"
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
trap 'hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true; rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true; lock_signing_keychain' EXIT
hdiutil attach -nobrowse -noverify -mountpoint "$MOUNT_POINT" "$DMG" >/dev/null
MOUNTED_APP="$MOUNT_POINT/Blurt.app"
[ -d "$MOUNTED_APP" ] || die "mounted DMG missing Blurt.app"
xcrun stapler validate "$MOUNTED_APP" >/dev/null
codesign --verify --strict --deep "$MOUNTED_APP"
MOUNTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNTED_APP/Contents/Info.plist")"
[ "$MOUNTED_VERSION" = "$VERSION" ] || die "version mismatch inside DMG: expected $VERSION, got $MOUNTED_VERSION"
hdiutil detach "$MOUNT_POINT" >/dev/null
rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
trap lock_signing_keychain EXIT
info "dmg contents verified (Blurt.app $MOUNTED_VERSION, signed + stapled)"

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
