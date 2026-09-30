#!/usr/bin/env bash
# Put a `release-build.sh --staging` build on the Sparkle staging feed: upload
# its DMG and appcast.xml to the sparkle-staging prerelease, creating that
# prerelease the first time. The update rehearsal in RELEASE.md installs one
# staged build by hand, stages a newer one with this script, and checks that the
# first updates itself to the second.
#
# The staging prerelease is never marked latest, so /releases/latest/download/ —
# the feed every shipped copy polls — can never resolve to it. Each run
# overwrites the previous staged assets; only the newest staged build matters.
#
# Normally runs as the release workflow's `stage` job. Also runnable locally
# after a local staging build, with `gh` signed in.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/App/Blurt"
BUILD_ROOT="$REPO_ROOT/build/release"

for arg in "$@"; do
  echo "unknown arg: $arg" >&2
  exit 2
done

# shellcheck source=scripts/release-lib.sh
source "$REPO_ROOT/scripts/release-lib.sh"

step "Preflight"
require_tools gh git awk shasum

VERSION="$(require_project_version "$APP_DIR/project.yml")"
DMG="$BUILD_ROOT/Blurt-$VERSION.dmg"
APPCAST="$BUILD_ROOT/appcast.xml"
CHECKSUMS="$BUILD_ROOT/SHA256SUMS"
BUILD_INFO="$BUILD_ROOT/build-info.txt"
for f in "$DMG" "$APPCAST" "$CHECKSUMS" "$BUILD_INFO"; do
  [ -f "$f" ] || die "$f not found — run scripts/release-build.sh --staging first"
done
CHANNEL="$(parse_build_info_channel <"$BUILD_INFO")"
[ "$CHANNEL" = staging ] \
  || die "$BUILD_INFO says channel '${CHANNEL:-none}' — only a --staging build may be staged (its feed must point here)"
info "version: $VERSION (channel: staging)"

step "Staging prerelease"
TAG="$SPARKLE_STAGING_TAG"
if gh release view "$TAG" >/dev/null 2>&1; then
  info "$TAG exists — overwriting its assets"
else
  gh release create "$TAG" \
    --target "$(git -C "$REPO_ROOT" rev-parse HEAD)" \
    --prerelease \
    --latest=false \
    --title "Sparkle staging (not a release)" \
    --notes "The update-rehearsal feed (RELEASE.md → Rehearsing an update). Not a Blurt release — download Blurt from the latest release instead."
  info "created $TAG"
fi

step "Upload"
# DMG before appcast: the feed should never name a DMG that isn't there yet.
gh release upload "$TAG" "$DMG" --clobber
gh release upload "$TAG" "$APPCAST" --clobber

step "Verify"
VERIFY_DIR="$(mktemp -d /tmp/blurt-stage.XXXXXX)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
gh release download "$TAG" --dir "$VERIFY_DIR" --pattern "Blurt-$VERSION.dmg" --pattern appcast.xml
verify_against_sums "$CHECKSUMS" "$VERIFY_DIR" "Blurt-$VERSION.dmg" appcast.xml
info "staged assets verified against SHA256SUMS"
info "feed: $(sparkle_feed_url staging)"
