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
# Ruby gem, so it can't live in the Brewfile with the rest. scripts/check-site.sh
# uses it for the Pages site's links/images/srcset/favicon/Open Graph and skips
# with a note when it is absent, which is missing coverage rather than a pass.
if ! command -v htmlproofer >/dev/null 2>&1; then
  echo "==> gem install html-proofer"
  gem install --no-document html-proofer
  GEM_BIN="$(gem environment | awk -F': ' '/EXECUTABLE DIRECTORY/{print $2}')"
  if [ -n "$GEM_BIN" ] && ! command -v htmlproofer >/dev/null 2>&1; then
    echo "note: htmlproofer installed to $GEM_BIN — add it to your PATH"
  fi
fi

echo "==> done"
echo "Installed tools from Brewfile, plus html-proofer (gem)."
