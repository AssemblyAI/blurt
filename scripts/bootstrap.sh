#!/bin/bash
# Install the local toolchain used by scripts/check.sh.
# Brewfile is the single source of truth for Homebrew-managed dependencies.
#
# Verifies the end state rather than trusting `brew bundle`'s exit code, because
# every linter is *optional* in check.sh — `tool_ready` notes a skip and moves on
# when a tool is absent. A bootstrap that half-worked therefore doesn't surface as
# a red check run; it surfaces as quietly reduced coverage. So the question this
# script answers is not "did brew exit 0" but "would check.sh skip anything", and
# it exits non-zero, naming the remedy, whenever the answer is yes.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BREWFILE="$REPO_ROOT/Brewfile"

if ! command -v brew >/dev/null 2>&1; then
  echo "error: Homebrew is required. Install it from https://brew.sh and rerun scripts/bootstrap.sh." >&2
  exit 1
fi

if [ ! -f "$BREWFILE" ]; then
  echo "error: no Brewfile at $BREWFILE" >&2
  exit 1
fi

# The command a formula is wanted for, when it differs from the formula name.
# check.sh probes the *binary*, so that — not the keg — is what has to exist.
command_for() {
  case "$1" in
    markdownlint-cli) echo markdownlint ;;
    *) echo "$1" ;;
  esac
}

# The explicit `install` subcommand: bare `brew bundle` is a legacy alias for it.
# Its exit status is recorded rather than fatal — under errexit a failure here
# would abort before the diagnosis below, which is the half a stuck bootstrap
# actually needs.
echo "==> brew bundle install"
bundle_status=0
brew bundle install --file="$BREWFILE" || bundle_status=$?

echo "==> verify"

# The authority on "is the Brewfile satisfied": unlike `brew list`, this fails on
# a formula that is installed but unlinked, which is exactly the state a link
# conflict leaves behind.
check_status=0
brew bundle check --file="$BREWFILE" --verbose || check_status=$?

# brew collapses several different problems into one exit code, so sort each
# Brewfile formula into the state that determines its fix. Reading Homebrew's
# linked-keg records under $HOMEBREW_PREFIX/var/homebrew/linked is an internal
# detail, so it only ever refines the *message*; `brew bundle check` above stays
# the authority on whether the Brewfile is satisfied.
absent=""      # not installed at all
shadowed=""    # installed, unlinked, but another copy of the tool answers anyway
unusable=""    # installed, unlinked, and nothing answers
unreachable="" # installed and linked, yet still not on PATH
installed="$(brew list --formula --versions)"
linked_records="$(brew --prefix)/var/homebrew/linked"
while IFS= read -r formula; do
  [ -n "$formula" ] || continue
  binary="$(command_for "$formula")"
  on_path=0
  command -v "$binary" >/dev/null 2>&1 && on_path=1
  if ! printf '%s\n' "$installed" | grep -q "^$formula "; then
    absent="$absent $formula"
  elif [ ! -e "$linked_records/$formula" ]; then
    if [ "$on_path" -eq 1 ]; then
      shadowed="$shadowed $formula"
    else
      unusable="$unusable $formula"
    fi
  elif [ "$on_path" -eq 0 ]; then
    unreachable="$unreachable $binary"
  fi
done <<EOF
$(brew bundle list --formula --file="$BREWFILE")
EOF

status=0

if [ -n "$absent" ]; then
  echo "error: not installed:$absent" >&2
  echo "       rerun scripts/bootstrap.sh, or install singly: brew install$absent" >&2
  status=1
fi

# A link conflict is the failure worth explaining. Homebrew reports it as
# "Installing <formula> has failed!", which reads like a download or build
# problem. It isn't: the keg is installed and only the symlink into the prefix
# lost to an unmanaged file that already owns the name — typically a pip- or
# npm-installed shim of the same tool (this repo hit it with pip's `ruff` and
# `pytest`). One command fixes it, so print it rather than leaving it to be
# scrolled back to.
if [ -n "$unusable" ]; then
  echo "error: installed but not linked, and no other copy on PATH:$unusable" >&2
  echo "       list what would be replaced: brew link --overwrite --dry-run$unusable" >&2
  echo "       then link for real:          brew link --overwrite$unusable" >&2
  status=1
fi

# Not an error: a working copy answers, so check.sh runs the tool rather than
# skipping it. Still worth saying, because the version it runs is whatever that
# other install channel pinned, not what the Brewfile did.
if [ -n "$shadowed" ]; then
  echo "note: installed but not linked:$shadowed"
  echo "      something Homebrew doesn't manage owns those names in $(brew --prefix)/bin"
  echo "      (usually a pip- or npm-installed copy), and check.sh will run that copy:"
  for formula in $shadowed; do
    echo "        $(command -v "$(command_for "$formula")")  (Homebrew's is unlinked)"
  done
  echo "      to hand them back to Homebrew: brew link --overwrite$shadowed"
  echo "      (add --dry-run first to list the files that would be replaced)"
fi

if [ -n "$unreachable" ]; then
  echo "error: installed and linked, but not on PATH:$unreachable" >&2
  echo "       check that $(brew --prefix)/bin is on PATH ahead of anything shadowing it." >&2
  status=1
fi

# A non-zero brew exit that none of the states above accounts for: defer to the
# output brew already printed rather than reporting a green bootstrap. `$shadowed`
# counts as accounted for — it is the one state that is deliberately not fatal.
if [ "$status" -eq 0 ] && [ -z "$shadowed" ] \
  && { [ "$bundle_status" -ne 0 ] || [ "$check_status" -ne 0 ]; }; then
  echo "error: brew bundle reported a failure (see its output above)." >&2
  status=1
fi

if [ "$status" -ne 0 ]; then
  exit 1
fi

echo "==> done"
echo "Every Brewfile tool is on PATH; scripts/check.sh will skip none of them."
