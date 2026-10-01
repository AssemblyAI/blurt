#!/usr/bin/env bash
# Bump CFBundleShortVersionString + CFBundleVersion in project.yml,
# regenerate the xcodeproj, and commit. Does not tag or push — that's
# release-publish.sh's job.
#
# Usage: scripts/release-bump.sh X.Y.Z

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/App/Blurt"
PROJECT_YML="$APP_DIR/project.yml"

# shellcheck source=scripts/release-lib.sh
source "$REPO_ROOT/scripts/release-lib.sh"

[ $# -eq 1 ] || die "usage: $(basename "$0") X.Y.Z"
NEW_VERSION="$1"
is_semver "$NEW_VERSION" || die "version must be X.Y.Z (got: $NEW_VERSION)"

step "Preflight"
require_tools xcodegen
[ -f "$PROJECT_YML" ] || die "not found: $PROJECT_YML"

require_clean_tree "bumping"

CURRENT_VERSION="$(require_project_version "$PROJECT_YML")"
CURRENT_BUILD="$(parse_bundle_version <"$PROJECT_YML")"
[ -n "$CURRENT_BUILD" ] || die "could not parse CFBundleVersion from $PROJECT_YML"
[[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || die "CFBundleVersion is not an integer: $CURRENT_BUILD"

[ "$NEW_VERSION" != "$CURRENT_VERSION" ] || die "version $NEW_VERSION is already current"
version_gt "$NEW_VERSION" "$CURRENT_VERSION" || die "$NEW_VERSION is not greater than current $CURRENT_VERSION"

if tag_exists_locally "v$NEW_VERSION"; then
  die "tag v$NEW_VERSION already exists locally"
fi
if tag_exists_on_origin "v$NEW_VERSION"; then
  die "tag v$NEW_VERSION already exists on origin"
fi

# Checked here, before anything is edited: the notes scaffold lists commits
# since the previous release tag, and failing for want of one after project.yml
# is rewritten would leave a dirty tree that blocks the re-run.
if [ ! -f "$(release_notes_path "$NEW_VERSION")" ] && [ -z "$(previous_release_tag "$NEW_VERSION")" ]; then
  die "no release tag below $NEW_VERSION to list commits from — fetch tags (fetch-depth: 0)"
fi

NEW_BUILD=$((CURRENT_BUILD + 1))
info "version: $CURRENT_VERSION → $NEW_VERSION"
info "build:   $CURRENT_BUILD → $NEW_BUILD"

step "Edit project.yml"
sed -i.bak -E \
  -e "s/^([[:space:]]*CFBundleShortVersionString:[[:space:]]*\")[^\"]*(\")/\\1$NEW_VERSION\\2/" \
  -e "s/^([[:space:]]*CFBundleVersion:[[:space:]]*\")[^\"]*(\")/\\1$NEW_BUILD\\2/" \
  "$PROJECT_YML"
rm -f "$PROJECT_YML.bak"

VERIFY_VERSION="$(parse_short_version <"$PROJECT_YML")"
VERIFY_BUILD="$(parse_bundle_version <"$PROJECT_YML")"
[ "$VERIFY_VERSION" = "$NEW_VERSION" ] || die "edit failed: short version is $VERIFY_VERSION, expected $NEW_VERSION"
[ "$VERIFY_BUILD" = "$NEW_BUILD" ] || die "edit failed: build is $VERIFY_BUILD, expected $NEW_BUILD"

step "xcodegen"
(cd "$APP_DIR" && xcodegen generate --quiet)

# The notes the update window will show. Scaffolded here with the commits since
# the previous release as context and a TODO that check.sh fails on, so the bump
# PR can't merge until a person has written them — reviewing that PR is the
# editorial pass. Notes someone already wrote ahead of the bump are kept.
step "Release notes"
NOTES_FILE="$(release_notes_path "$NEW_VERSION")"
if [ -f "$NOTES_FILE" ]; then
  info "keeping existing $NOTES_FILE"
else
  NOTES_FILE="$(scaffold_release_notes "$NEW_VERSION")"
  info "scaffolded $NOTES_FILE — write the notes in the bump PR"
fi

step "Commit"
# xcodegen regenerates the (tracked) Info.plist from project.yml's version
# properties, so it must be committed alongside the project files — otherwise
# the bump leaves it dirty and the next build/publish trips the clean-tree gate.
git -C "$REPO_ROOT" add "$PROJECT_YML" "$APP_DIR/Blurt.xcodeproj" "$APP_DIR/Blurt/Info.plist" "$NOTES_FILE"
git -C "$REPO_ROOT" commit -m "chore: bump to v$NEW_VERSION"

step "Next steps"
cat <<EOF

  Bumped to v$NEW_VERSION (build $NEW_BUILD). Next:
    \$EDITOR ${NOTES_FILE#"$REPO_ROOT"/}   # write the update-window notes
    scripts/release-build.sh      # build, sign, notarize, staple DMG
    scripts/release-publish.sh    # tag v$NEW_VERSION, push, publish GitHub Release

EOF
