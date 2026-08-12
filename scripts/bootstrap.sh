#!/bin/bash
# Install the local toolchain used by scripts/check.sh.
# Brewfile is the single source of truth for Homebrew-managed dependencies.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v brew >/dev/null 2>&1; then
  echo "error: Homebrew is required. Install it from https://brew.sh and rerun scripts/bootstrap.sh."
  exit 1
fi

echo "==> brew bundle"
cd "$REPO_ROOT"
brew bundle --file="$REPO_ROOT/Brewfile"

# html-proofer is the one check.sh tool with no Homebrew formula — it ships as a
# Ruby gem, so the repo's Gemfile carries it instead of the Brewfile.
# scripts/check-site.sh uses it for the Pages site's links/images/srcset/favicon/
# Open Graph, and runs it via `bundle exec` so the pinned version is the one that
# gates the site.
echo "==> bundle install (html-proofer)"
if command -v bundle >/dev/null 2>&1; then
  bundle install --quiet
else
  echo "note: bundler not found; skipping html-proofer (check-site.sh will note the gap)"
fi

echo "==> done"
echo "Installed tools from Brewfile, plus html-proofer (Gemfile)."
