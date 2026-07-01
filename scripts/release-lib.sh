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
