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

info()  { printf '\033[34m▸\033[0m %s\n' "$*"; }
step()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die()   { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: $(basename "$0") X.Y.Z"
NEW_VERSION="$1"
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z (got: $NEW_VERSION)"

step "Preflight"
command -v xcodegen >/dev/null 2>&1 || die "missing required tool: xcodegen"
[ -f "$PROJECT_YML" ] || die "not found: $PROJECT_YML"

if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
  die "working tree dirty — commit or stash before bumping"
fi

CURRENT_VERSION="$(awk '/CFBundleShortVersionString:/ {gsub(/"/,"",$2); print $2; exit}' "$PROJECT_YML")"
CURRENT_BUILD="$(awk '/CFBundleVersion:/ {gsub(/"/,"",$2); print $2; exit}' "$PROJECT_YML")"
[ -n "$CURRENT_VERSION" ] || die "could not parse CFBundleShortVersionString from $PROJECT_YML"
[ -n "$CURRENT_BUILD" ] || die "could not parse CFBundleVersion from $PROJECT_YML"
[[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || die "CFBundleVersion is not an integer: $CURRENT_BUILD"

[ "$NEW_VERSION" != "$CURRENT_VERSION" ] || die "version $NEW_VERSION is already current"

LOWER="$(printf '%s\n%s\n' "$CURRENT_VERSION" "$NEW_VERSION" | sort -V | head -n1)"
[ "$LOWER" = "$CURRENT_VERSION" ] || die "$NEW_VERSION is not greater than current $CURRENT_VERSION"

if git -C "$REPO_ROOT" rev-parse "v$NEW_VERSION" >/dev/null 2>&1; then
  die "tag v$NEW_VERSION already exists locally"
fi
if git -C "$REPO_ROOT" ls-remote --tags origin "refs/tags/v$NEW_VERSION" 2>/dev/null | grep -q .; then
  die "tag v$NEW_VERSION already exists on origin"
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

VERIFY_VERSION="$(awk '/CFBundleShortVersionString:/ {gsub(/"/,"",$2); print $2; exit}' "$PROJECT_YML")"
VERIFY_BUILD="$(awk '/CFBundleVersion:/ {gsub(/"/,"",$2); print $2; exit}' "$PROJECT_YML")"
[ "$VERIFY_VERSION" = "$NEW_VERSION" ] || die "edit failed: short version is $VERIFY_VERSION, expected $NEW_VERSION"
[ "$VERIFY_BUILD" = "$NEW_BUILD" ] || die "edit failed: build is $VERIFY_BUILD, expected $NEW_BUILD"

step "xcodegen"
(cd "$APP_DIR" && xcodegen generate --quiet)

step "Commit"
# xcodegen regenerates the (tracked) Info.plist from project.yml's version
# properties, so it must be committed alongside the project files — otherwise
# the bump leaves it dirty and the next build/publish trips the clean-tree gate.
git -C "$REPO_ROOT" add "$PROJECT_YML" "$APP_DIR/Blurt.xcodeproj" "$APP_DIR/Blurt/Info.plist"
git -C "$REPO_ROOT" commit -m "chore: bump to v$NEW_VERSION"

step "Next steps"
cat <<EOF

  Bumped to v$NEW_VERSION (build $NEW_BUILD). Next:
    scripts/release-build.sh      # build, sign, notarize, staple DMG
    scripts/release-publish.sh    # tag v$NEW_VERSION, push, publish GitHub Release

EOF
