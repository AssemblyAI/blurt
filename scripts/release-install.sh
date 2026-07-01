#!/usr/bin/env bash
# Install the notarized release build locally so you can test the exact
# artifact users will get, before publishing. Mounts the DMG produced by
# release-build.sh and copies Blurt.app out of it into /Applications
# (falling back to ~/Applications). The app inside the DMG is already signed,
# stapled, and secure-timestamped — it is copied AS-IS and never re-signed,
# since re-signing would invalidate the notarization staple.
#
# Safe to re-run. Reads the version from project.yml; run release-build.sh first.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/App/Blurt"
BUILD_ROOT="$REPO_ROOT/build/release"
DERIVED="$BUILD_ROOT/derived"

info() { printf '\033[34m▸\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die() {
  printf '\033[31m✗\033[0m %s\n' "$*" >&2
  exit 1
}

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

step "Preflight"
for cmd in xcrun hdiutil codesign ditto awk; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing required tool: $cmd"
done

VERSION="$(awk '/CFBundleShortVersionString:/ {gsub(/"/, "", $2); print $2; exit}' "$APP_DIR/project.yml")"
[ -n "$VERSION" ] || die "could not parse CFBundleShortVersionString from $APP_DIR/project.yml"
info "version: $VERSION"

DMG="$BUILD_ROOT/Blurt-$VERSION.dmg"
[ -f "$DMG" ] || die "DMG not found at $DMG — run scripts/release-build.sh first"

step "Validate staple"
xcrun stapler validate "$DMG" >/dev/null 2>&1 || die "DMG not stapled — rebuild with release-build.sh"
info "dmg stapled: $DMG"

step "Choose install location"
if [ -w /Applications ]; then
  DEST="/Applications/Blurt.app"
else
  DEST="$HOME/Applications/Blurt.app"
  mkdir -p "$HOME/Applications"
fi
info "destination: $DEST"

step "Quit running Blurt"
# A running bundle can't be replaced cleanly. Ask it to quit, then fall back
# to a hard kill; either way wait briefly for the process to exit.
if pgrep -x Blurt >/dev/null 2>&1; then
  osascript -e 'quit app "Blurt"' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    pgrep -x Blurt >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -x Blurt >/dev/null 2>&1 || true
  info "quit running Blurt"
else
  info "Blurt not running"
fi

step "Mount DMG"
# Own mount point so we don't have to parse hdiutil's output (which reports
# /private/tmp/... rather than /tmp/... on macOS). Detach + cleanup on exit.
MOUNT_POINT="$(mktemp -d /tmp/blurt-install.XXXXXX)"
trap 'hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true; rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true' EXIT
hdiutil attach -nobrowse -noverify -mountpoint "$MOUNT_POINT" "$DMG" >/dev/null
MOUNTED_APP="$MOUNT_POINT/Blurt.app"
[ -d "$MOUNTED_APP" ] || die "mounted DMG missing Blurt.app"

step "Install"
rm -rf "$DEST"
# ditto preserves the bundle's signature, staple, and extended attributes
# exactly — a plain cp can drop xattrs the notarization ticket relies on.
ditto "$MOUNTED_APP" "$DEST"
hdiutil detach "$MOUNT_POINT" >/dev/null
rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
trap - EXIT

step "Verify installed bundle"
xcrun stapler validate "$DEST" >/dev/null || die "installed app failed staple validation: $DEST"
codesign --verify --strict --deep "$DEST" || die "installed app failed signature verification: $DEST"
INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
[ "$INSTALLED_VERSION" = "$VERSION" ] \
  || die "installed version mismatch: expected $VERSION, got $INSTALLED_VERSION"
info "installed bundle verified ($INSTALLED_VERSION, signed + stapled)"

step "Register with LaunchServices"
# Repeated release builds leave a Blurt.app copy in build/release/derived
# claiming the same bundle id; if it lingers, macOS can resolve the id to that
# transient path and the install vanishes from the Accessibility list. Drop the
# build copy and (re)register the install so the id resolves to a stable path.
if [ -x "$LSREGISTER" ]; then
  DERIVED_APP="$DERIVED/Build/Products/Release/Blurt.app"
  [ -d "$DERIVED_APP" ] && "$LSREGISTER" -u "$DERIVED_APP" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
  info "registered: $DEST"
else
  info "lsregister not found — skipping registration"
fi

step "Done"
cat <<EOF

  Installed release v$VERSION to:
    $DEST

  Test it now — relaunch Blurt and dictate. Same bundle id + Developer ID
  as your previous install, so existing Accessibility / Microphone grants
  carry over. If permissions misbehave, reset them with:
    scripts/reset-install.sh

  When you're satisfied, confirm the publish prompt (or run):
    scripts/release-publish.sh
EOF
