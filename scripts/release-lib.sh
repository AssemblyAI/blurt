#!/usr/bin/env bash
# Shared helpers for the release scripts (release.sh, release-bump.sh,
# release-build.sh, release-install.sh, release-publish.sh). Sourced, never
# executed. Everything here must stay side-effect-free at source time —
# release.test.sh sources release.sh (which sources this) to unit-test the
# pure helpers.

# --- logging ---

info() { printf '\033[34m▸\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die() {
  printf '\033[31m✗\033[0m %s\n' "$*" >&2
  exit 1
}

# --- shared guards (need REPO_ROOT set by the sourcing script) ---

# Die unless the git working tree is clean; $1 names the action for the message
# (e.g. "publishing" -> "… commit or stash before publishing").
require_clean_tree() {
  [ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] \
    || die "working tree dirty — commit or stash before ${1:-continuing}"
}

# Echo CFBundleShortVersionString read from the project.yml at $1, dying when
# it can't be parsed. Call as: VERSION="$(require_project_version "$path")" —
# the die inside the substitution fails the assignment under `set -e`.
require_project_version() {
  local version
  version="$(parse_short_version <"$1")"
  [ -n "$version" ] || die "could not parse CFBundleShortVersionString from $1"
  printf '%s\n' "$version"
}

# True if tag $1 (e.g. "v1.2.3") exists in the local repo.
tag_exists_locally() {
  git -C "$REPO_ROOT" rev-parse "$1" >/dev/null 2>&1
}

# True if tag $1 exists on origin.
tag_exists_on_origin() {
  git -C "$REPO_ROOT" ls-remote --tags origin "refs/tags/$1" 2>/dev/null | grep -q .
}

# True if codesigning identity $1 (a SHA-1 hash) appears in the
# `security find-identity -v -p codesigning` output piped on stdin.
identity_listed() {
  grep -qF -- "$1"
}

# --- pure version helpers (unit-tested by scripts/release.test.sh) ---

# True if $1 looks like X.Y.Z (digits only).
is_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# True if version $1 is strictly greater than version $2 (semver-ordered).
version_gt() {
  [ "$1" != "$2" ] || return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# Read CFBundleShortVersionString from project.yml content on stdin. The one
# definition of the version-read rule every release script gates on.
parse_short_version() {
  awk '/CFBundleShortVersionString:/ {gsub(/"/, "", $2); print $2; exit}'
}

# Read CFBundleVersion (the integer build number) from project.yml on stdin.
parse_bundle_version() {
  awk '/CFBundleVersion:/ {gsub(/"/, "", $2); print $2; exit}'
}

# Read the full commit SHA from build-info.txt content on stdin.
parse_build_info_git_sha() {
  awk '/^git:[[:space:]]+/ {print $2; exit}'
}
