#!/usr/bin/env bash
# Build, sign, notarize, and staple a release DMG into build/release/.
# Reproducible; safe to re-run. The publish step is a separate script.
#
# Normally runs on CI (.github/workflows/release.yml), where the signing key and
# the notary credential arrive as secrets; still runnable on a Mac with the key
# in a local keychain, for debugging a single stage. See RELEASE.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/App/Blurt"
BUILD_ROOT="$REPO_ROOT/build/release"
DERIVED="$BUILD_ROOT/derived"
STAGE="$BUILD_ROOT/stage"
ENTITLEMENTS="$APP_DIR/Blurt/Blurt.entitlements"

readonly IDENTITY="602F699488189767137DF15633B967B1371ACD86"
# SHA-256 fingerprint of the same Developer ID leaf cert as IDENTITY (which is
# its SHA-1 identity hash, the only format `codesign --sign` accepts). The
# signer-pin verifies produced artifacts against this stronger digest.
readonly IDENTITY_SHA256="3FD515692E25B96159AEFA3BEE9643EB4D804CF1B95012EEF0E9B8E3B98F207F"
readonly TEAM_ID="B2VQF7Q2QY"
readonly NOTARY_PROFILE="blurt-notary"

SKIP_CHECKS=0
SKIP_SMOKE=0
for arg in "$@"; do
  case "$arg" in
    --skip-checks) SKIP_CHECKS=1 ;;
    --skip-smoke) SKIP_SMOKE=1 ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

# shellcheck source=scripts/release-lib.sh
source "$REPO_ROOT/scripts/release-lib.sh"

# --- Where the signing key comes from -----------------------------------------
# Two custody models, one build script:
#
#   CI    — BLURT_SIGNING_P12_BASE64 carries the Developer ID cert + key as a
#           base64 .p12 secret. It is imported into an EPHEMERAL keychain that
#           exists only for this run and is deleted on exit, so the key never
#           lands in a persistent store on the runner.
#   Local — a dedicated keychain that stays LOCKED at rest instead of living in
#           login. Unlocked for the duration of the build and re-locked on exit.
#           If that keychain isn't present — a machine that still keeps the key
#           in login, or mid-migration — fall through to whatever's already on
#           the search list so releases keep working.
SIGNING_KEYCHAIN="${BLURT_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/blurt-signing.keychain-db}"
SIGNING_KEYCHAIN_UNLOCKED=0
CI_KEYCHAIN=""
CI_KEYCHAIN_DIR=""

# notarytool --keychain args, populated once the signing keychain is unlocked so
# every notary call resolves the profile from THAT keychain rather than from
# whatever the search list happens to surface. Without this, a stray duplicate
# blurt-notary profile in another keychain (e.g. one electron-builder created)
# can shadow the intended one, and which profile wins depends on search-list
# order and lock state — non-deterministic. Empty on machines with no dedicated
# signing keychain, where we fall back to the search list.
# shellcheck disable=SC2034  # expanded via ${NOTARY_KEYCHAIN[@]+...} below
NOTARY_KEYCHAIN=()

# Echo the user keychain search list, one unquoted path per line.
keychain_search_list() {
  security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/^"//' -e 's/"$//'
}

# Put keychain $1 at the front of the user search list, keeping the entries
# already there (a bare `list-keychains -s <one>` would replace login + System).
prepend_to_search_list() {
  local target="$1" k present=0
  local -a search=()
  while IFS= read -r k; do
    [ -n "$k" ] && search+=("$k")
  done < <(keychain_search_list)
  for k in "${search[@]}"; do [ "$k" = "$target" ] && present=1; done
  [ "$present" -eq 1 ] || security list-keychains -d user -s "$target" "${search[@]}"
}

# Resolve the keychain password, in order:
#   1. BLURT_SIGNING_KEYCHAIN_PASSWORD — env (a CI secret, or `op read` inline).
#   2. BLURT_SIGNING_KEYCHAIN_OP — an `op://…` 1Password secret reference; the
#      script runs `op read` on it (Touch ID fires via the desktop app). Set
#      OP_ACCOUNT if you're signed into multiple 1Password accounts. Export this
#      once in your shell so a bare `scripts/release.sh` unlocks via 1Password.
#   3. Interactive prompt.
# Deliberately NOT read from the login keychain — the whole point of the
# dedicated keychain is that its unlock secret does not sit in login (where any
# process running as you can read it while you're logged in).
#
# The password is assigned into the global SIGNING_KEYCHAIN_PW rather than echoed
# to stdout, so the secret is never emitted where a command substitution, a log,
# or `set -x` could capture it. The caller reads SIGNING_KEYCHAIN_PW and unsets
# it immediately after use.
SIGNING_KEYCHAIN_PW=""
load_signing_keychain_password() {
  if [ -n "${BLURT_SIGNING_KEYCHAIN_PASSWORD:-}" ]; then
    SIGNING_KEYCHAIN_PW="$BLURT_SIGNING_KEYCHAIN_PASSWORD"
    return 0
  fi
  if [ -n "${BLURT_SIGNING_KEYCHAIN_OP:-}" ] && command -v op >/dev/null 2>&1; then
    SIGNING_KEYCHAIN_PW="$(op read "$BLURT_SIGNING_KEYCHAIN_OP")" \
      || die "op read failed for $BLURT_SIGNING_KEYCHAIN_OP (signed in? set OP_ACCOUNT if you have multiple accounts)"
    [ -n "$SIGNING_KEYCHAIN_PW" ] || die "op read returned empty for $BLURT_SIGNING_KEYCHAIN_OP"
    return 0
  fi
  read -rsp "Password for signing keychain ($SIGNING_KEYCHAIN): " SIGNING_KEYCHAIN_PW </dev/tty \
    || die "no signing keychain password provided (set BLURT_SIGNING_KEYCHAIN_PASSWORD)"
  printf '\n' >&2
}

unlock_signing_keychain() {
  if [ ! -f "$SIGNING_KEYCHAIN" ]; then
    info "no dedicated signing keychain at $SIGNING_KEYCHAIN — using existing search list"
    return 0
  fi
  prepend_to_search_list "$SIGNING_KEYCHAIN"

  load_signing_keychain_password
  security unlock-keychain -p "$SIGNING_KEYCHAIN_PW" "$SIGNING_KEYCHAIN" \
    || {
      SIGNING_KEYCHAIN_PW=""
      die "failed to unlock signing keychain $SIGNING_KEYCHAIN"
    }
  SIGNING_KEYCHAIN_PW=""
  SIGNING_KEYCHAIN_UNLOCKED=1
  info "unlocked dedicated signing keychain: $SIGNING_KEYCHAIN"
}

lock_signing_keychain() {
  [ "$SIGNING_KEYCHAIN_UNLOCKED" -eq 1 ] || return 0
  security lock-keychain "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
  SIGNING_KEYCHAIN_UNLOCKED=0
}

# Import the Developer ID cert + key from the BLURT_SIGNING_P12_BASE64 secret
# into a keychain created for this build alone. Nothing persists: the keychain
# file lives in a temp dir and `delete_ci_keychain` (wired into the EXIT trap)
# removes it whether the build succeeds or dies.
create_ci_keychain() {
  local p12 kc_pw
  [ -n "${BLURT_SIGNING_P12_PASSWORD:-}" ] \
    || die "BLURT_SIGNING_P12_BASE64 is set but BLURT_SIGNING_P12_PASSWORD is not — the .p12 export password is required to import it"

  CI_KEYCHAIN_DIR="$(mktemp -d /tmp/blurt-ci-keychain.XXXXXX)" || die "mktemp failed for the ephemeral keychain"
  CI_KEYCHAIN="$CI_KEYCHAIN_DIR/blurt-signing.keychain-db"
  # Random per-run password: it protects a keychain that outlives nothing, so
  # it never has to be known outside this process.
  kc_pw="$(openssl rand -base64 24)" || die "could not generate an ephemeral keychain password"
  security create-keychain -p "$kc_pw" "$CI_KEYCHAIN" || die "could not create the ephemeral keychain"
  # No auto-lock and no lock-on-sleep: a relock partway through would fail the
  # signing steps, and the keychain is destroyed on exit regardless.
  security set-keychain-settings "$CI_KEYCHAIN"
  security unlock-keychain -p "$kc_pw" "$CI_KEYCHAIN" || die "could not unlock the ephemeral keychain"

  p12="$(mktemp)" || die "mktemp failed for the signing .p12"
  chmod 600 "$p12"
  # openssl rather than base64(1): -A accepts the secret whether it arrives as
  # one long line or wrapped, which the platform base64 flags do not agree on.
  printf '%s' "$BLURT_SIGNING_P12_BASE64" | openssl base64 -d -A >"$p12" \
    || {
      rm -f "$p12"
      die "BLURT_SIGNING_P12_BASE64 is not valid base64"
    }
  # -T pre-authorizes those tools; set-key-partition-list below is what actually
  # makes that stick on modern macOS (without it codesign blocks on a UI prompt
  # that no CI runner can answer).
  security import "$p12" -k "$CI_KEYCHAIN" -P "$BLURT_SIGNING_P12_PASSWORD" \
    -f pkcs12 -T /usr/bin/codesign -T /usr/bin/security >/dev/null \
    || {
      rm -f "$p12"
      die "could not import the signing .p12 (wrong BLURT_SIGNING_P12_PASSWORD, or the secret isn't a PKCS#12 export?)"
    }
  rm -f "$p12"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kc_pw" "$CI_KEYCHAIN" >/dev/null \
    || die "could not set the partition list on the ephemeral keychain"

  prepend_to_search_list "$CI_KEYCHAIN"
  info "imported the signing identity into an ephemeral keychain: $CI_KEYCHAIN"
}

delete_ci_keychain() {
  [ -n "$CI_KEYCHAIN" ] || return 0
  security delete-keychain "$CI_KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$CI_KEYCHAIN_DIR"
  CI_KEYCHAIN=""
  CI_KEYCHAIN_DIR=""
}

# Build the notarytool credential arguments once, so the preflight below and
# every submission authenticate identically. In order:
#
#   1. App Store Connect API key (issuer + key id + base64 .p8) — the CI path.
#      Revocable on its own, unlike an Apple ID app-specific password, needs no
#      keychain, and never appears in the process list.
#   2. Apple ID + app-specific password — the CI fallback for a team without
#      API-key access. NOTE: --password puts the secret on notarytool's command
#      line, readable by other processes on the same host; fine on a throwaway
#      runner, not something to adopt on a shared machine.
#   3. The `blurt-notary` keychain profile — the local path, pinned to the
#      dedicated signing keychain when there is one (see NOTARY_KEYCHAIN).
NOTARY_AUTH=()
NOTARY_KEY_FILE=""
NOTARY_AUTH_KIND=""
resolve_notary_auth() {
  if [ -n "${BLURT_NOTARY_KEY_P8_BASE64:-}" ]; then
    [ -n "${BLURT_NOTARY_KEY_ID:-}" ] || die "BLURT_NOTARY_KEY_P8_BASE64 is set but BLURT_NOTARY_KEY_ID is not"
    [ -n "${BLURT_NOTARY_ISSUER_ID:-}" ] || die "BLURT_NOTARY_KEY_P8_BASE64 is set but BLURT_NOTARY_ISSUER_ID is not"
    NOTARY_KEY_FILE="$(mktemp)" || die "mktemp failed for the notary API key"
    chmod 600 "$NOTARY_KEY_FILE"
    printf '%s' "$BLURT_NOTARY_KEY_P8_BASE64" | openssl base64 -d -A >"$NOTARY_KEY_FILE" \
      || die "BLURT_NOTARY_KEY_P8_BASE64 is not valid base64"
    NOTARY_AUTH=(--key "$NOTARY_KEY_FILE" --key-id "$BLURT_NOTARY_KEY_ID" --issuer "$BLURT_NOTARY_ISSUER_ID")
    NOTARY_AUTH_KIND="App Store Connect API key $BLURT_NOTARY_KEY_ID"
  elif [ -n "${BLURT_NOTARY_APPLE_ID:-}" ] && [ -n "${BLURT_NOTARY_PASSWORD:-}" ]; then
    NOTARY_AUTH=(--apple-id "$BLURT_NOTARY_APPLE_ID" --team-id "$TEAM_ID" --password "$BLURT_NOTARY_PASSWORD")
    NOTARY_AUTH_KIND="Apple ID $BLURT_NOTARY_APPLE_ID"
  else
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE" ${NOTARY_KEYCHAIN[@]+"${NOTARY_KEYCHAIN[@]}"})
    NOTARY_AUTH_KIND="keychain profile $NOTARY_PROFILE"
  fi
  info "notary auth: $NOTARY_AUTH_KIND"
}

# One cleanup, one trap: re-lock the local signing keychain, destroy the
# ephemeral CI one, shred the decoded notary key, and unmount a DMG left
# attached by a failure partway through the verify step.
MOUNT_POINT=""
cleanup() {
  if [ -n "$MOUNT_POINT" ]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
    MOUNT_POINT=""
  fi
  if [ -n "$NOTARY_KEY_FILE" ]; then
    rm -f "$NOTARY_KEY_FILE"
    NOTARY_KEY_FILE=""
  fi
  delete_ci_keychain
  lock_signing_keychain
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
    "${NOTARY_AUTH[@]}" \
    --wait \
    --output-format plist >"$result_plist"
  local status id
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$result_plist" 2>/dev/null || echo unknown)"
  id="$(/usr/libexec/PlistBuddy -c 'Print :id' "$result_plist" 2>/dev/null || echo unknown)"
  info "notary status ($tag): $status (id $id)"
  xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >"$log_json" 2>&1 || true
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
# Echo the crash reports that appeared since the listing in $1 (a `crash_list`
# snapshot). One definition: both smoke-test exits ask the same question, and a
# copy of the comm/printf pairing at each was a chance for them to disagree about
# what "new" means.
new_crashes() {
  comm -13 <(printf '%s\n' "$1") <(printf '%s\n' "$(crash_list)")
}
smoke_launch() {
  local app="$1" before new
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
    new="$(new_crashes "$before")"
    die "smoke test: Blurt exited within 2s of launch${new:+ (new crash report: $new)}"
  fi
  sleep 3
  new="$(new_crashes "$before")"
  osascript -e 'tell application "Blurt" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x Blurt >/dev/null 2>&1 || true
  [ -z "$new" ] || die "smoke test: new crash report(s) after launch: $new"
  info "smoke test: launched, stayed up 5s, no crash report"
}

pretty_xcodebuild

step "Preflight"
require_tools --hint='brew install create-dmg if needed' \
  xcodegen xcodebuild xcrun hdiutil codesign spctl create-dmg awk shasum openssl

# Destroy every credential this build materializes, no matter how we exit
# (success, die, or a mid-build failure). Armed before the first one exists so
# there is no window where a temp keychain or decoded key could outlive us.
trap cleanup EXIT

if [ -n "${BLURT_SIGNING_P12_BASE64:-}" ]; then
  create_ci_keychain
else
  unlock_signing_keychain
fi

# Resolve the notary credential only AFTER the keychain work: on the local path,
# the blurt-notary profile is expected to live in the dedicated signing keychain,
# and we pin every notary call to it (see NOTARY_KEYCHAIN) so the lookup is
# deterministic rather than at the mercy of the search list.
if [ "$SIGNING_KEYCHAIN_UNLOCKED" -eq 1 ]; then
  NOTARY_KEYCHAIN=(--keychain "$SIGNING_KEYCHAIN")
fi
resolve_notary_auth

# A cheap authenticated call: proves the credential actually works before we
# spend a full build getting to the first submission.
if ! xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1; then
  case "$NOTARY_AUTH_KIND" in
    "keychain profile"*)
      if [ "$SIGNING_KEYCHAIN_UNLOCKED" -eq 1 ]; then
        die "notarytool profile '$NOTARY_PROFILE' not found in $SIGNING_KEYCHAIN. Store it there: xcrun notarytool store-credentials $NOTARY_PROFILE --keychain $SIGNING_KEYCHAIN --apple-id <you@example.com> --team-id $TEAM_ID --password <app-specific-password>"
      else
        die "notarytool profile '$NOTARY_PROFILE' not found. Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <you@example.com> --team-id $TEAM_ID --password <app-specific-password>"
      fi
      ;;
    *) die "the notary credential ($NOTARY_AUTH_KIND) was rejected by Apple — check the secret's value and that it is still valid for team $TEAM_ID" ;;
  esac
fi

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
# Assigning MOUNT_POINT is what arms the unmount: `cleanup` (already the EXIT
# trap) detaches whatever it names, so a failure between here and the detach
# below can't leave the image attached.
MOUNT_POINT="$(mktemp -d /tmp/blurt-dmg.XXXXXX)"
hdiutil attach -nobrowse -noverify -mountpoint "$MOUNT_POINT" "$DMG" >/dev/null
MOUNTED_APP="$MOUNT_POINT/Blurt.app"
[ -d "$MOUNTED_APP" ] || die "mounted DMG missing Blurt.app"
xcrun stapler validate "$MOUNTED_APP" >/dev/null
codesign --verify --strict --deep "$MOUNTED_APP"
MOUNTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNTED_APP/Contents/Info.plist")"
[ "$MOUNTED_VERSION" = "$VERSION" ] || die "version mismatch inside DMG: expected $VERSION, got $MOUNTED_VERSION"
hdiutil detach "$MOUNT_POINT" >/dev/null
rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
MOUNT_POINT=""
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
} >"$PROVENANCE"
info "provenance: $PROVENANCE"

step "Checksums"
CHECKSUMS="$BUILD_ROOT/SHA256SUMS"
(cd "$BUILD_ROOT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$DSYM_ZIP")") >"$CHECKSUMS"
info "checksums: $CHECKSUMS"

step "Summary"
SIZE="$(du -h "$DMG" | cut -f1)"
SHA="$(sha256_of_file "$DMG")"
cat <<EOF

  DMG:        $DMG
  Size:       $SIZE
  SHA256:     $SHA
  dSYM:       $DSYM_DST
  Checksums:  $CHECKSUMS
  Provenance: $PROVENANCE
  Notary log: $NOTARY_LOG

  In CI the release workflow uploads these as run artifacts and the gated
  publish job takes it from here. Running locally, install to test and publish:
    scripts/release-install.sh    # install the notarized build to /Applications
    scripts/release-publish.sh    # tag, push, publish the GitHub Release
EOF
