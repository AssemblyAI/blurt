#!/usr/bin/env bash
# Lint every docs/release-notes/X.Y.Z.md — the text Blurt's update window shows
# (RELEASE.md → Release notes). Fails on a leftover TODO from the bump PR's
# scaffold and on anything `lint_release_notes` in release-lib.sh rejects.
# Run by check.sh; also useful on its own while writing notes.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/release-lib.sh
source "$REPO_ROOT/scripts/release-lib.sh"

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
