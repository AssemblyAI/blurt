#!/usr/bin/env bash
# Lint every docs/release-notes/X.Y.Z.md — the text Blurt's update window shows
# (RELEASE.md → Release notes). Fails on a leftover TODO from the bump PR's
# scaffold and on anything `lint_release_notes` in release-lib.sh rejects.
# Run by check.sh; also useful on its own while writing notes.
#
#   scripts/check-release-notes.sh             lint every notes file
#   scripts/check-release-notes.sh --new X.Y.Z  scaffold X.Y.Z.md, as the bump does
#
# --new is for a version that has to be built without going through
# release-bump.sh — re-running or republishing a version bumped before notes
# were required. It lists the commits since the release below X.Y.Z.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/release-lib.sh
source "$REPO_ROOT/scripts/release-lib.sh"

if [ "${1:-}" = "--new" ]; then
  if [ $# -ne 2 ] || ! is_semver "$2"; then die "usage: $(basename "$0") --new X.Y.Z"; fi
  NOTES_FILE="$(release_notes_path "$2")"
  [ ! -f "$NOTES_FILE" ] || die "$NOTES_FILE already exists"
  PREV_VERSION="$(previous_release_tag "$2")"
  [ -n "$PREV_VERSION" ] || die "no release tag below $2 to list commits from — fetch tags"
  mkdir -p "$(dirname "$NOTES_FILE")"
  git -C "$REPO_ROOT" log --format=%s "v$PREV_VERSION..HEAD" | release_notes_template "$PREV_VERSION" >"$NOTES_FILE"
  info "scaffolded $NOTES_FILE — replace the TODO, then commit it"
  exit 0
fi
[ $# -eq 0 ] || die "unknown argument: $1 (the only flag is --new X.Y.Z)"

shopt -s nullglob
files=("$REPO_ROOT"/docs/release-notes/*.md)
if [ "${#files[@]}" -eq 0 ]; then
  echo "no release notes to lint"
  exit 0
fi

failed=0
for f in "${files[@]}"; do
  name="${f#"$REPO_ROOT"/}"
  version="$(basename "$f" .md)"
  if ! is_semver "$version"; then
    echo "$name: not named X.Y.Z.md — the release build looks notes up by version"
    failed=1
    continue
  fi
  if out="$(lint_release_notes <"$f")"; then
    echo "ok   $name"
  else
    printf '%s\n' "$out" | sed "s|^|$name: |"
    failed=1
  fi
done
exit "$failed"
