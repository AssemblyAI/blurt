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

echo "==> done"
echo "Installed tools from Brewfile."
