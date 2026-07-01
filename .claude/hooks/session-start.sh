#!/bin/bash
# SessionStart hook: prepare a Claude Code on the web (Linux) sandbox.
#
# Blurt is macOS-only, so the Swift toolchain can't run here — but the portable
# checks (prettier / xmllint / markdownlint / shellcheck / actionlint /
# release.test.sh) can. This hook installs the missing portable linters so
# `scripts/check.sh --portable` works, then prints a one-line preflight so the
# session starts knowing CI (macos-26) is the authority on green.
#
# Local (macOS) sessions are untouched: the hook exits immediately unless
# CLAUDE_CODE_REMOTE=true. Idempotent — every install is guarded on
# `command -v`, so a warm (cached) container skips straight through. Installs
# degrade to a note rather than failing the hook: the portable check skips
# absent tools the same way check.sh always has.
#
# SwiftLint and swift-format are NOT installed: their Linux builds ship as
# GitHub release binaries, which the default web network policy blocks (only
# npm / apt / the Go module proxy are reachable). Swift formatting and lint
# therefore stay a CI concern on the web — the PostToolUse hooks no-op cleanly
# when the tools are absent.
set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

note() { echo "session-start: $*"; }

# markdownlint (npm) — check.sh's Markdown structural lint.
if ! command -v markdownlint >/dev/null 2>&1; then
  npm install -g markdownlint-cli >/dev/null 2>&1 || note "markdownlint install failed (npm)"
fi

# prettier (npm) — formatting authority for yml/yaml/md/html/css. Usually
# preinstalled in the web sandbox; this is a fallback.
if ! command -v prettier >/dev/null 2>&1; then
  npm install -g prettier >/dev/null 2>&1 || note "prettier install failed (npm)"
fi

# ShellCheck (pip) — static analysis for scripts/*.sh. shellcheck-py bundles a
# current binary, matching the brew version CI uses. Deliberately NOT apt:
# Ubuntu noble ships 0.9.0, which flags SC2015 info findings in scripts that
# CI's newer shellcheck accepts — a false red.
if ! command -v shellcheck >/dev/null 2>&1 && command -v pip3 >/dev/null 2>&1; then
  pip3 install --quiet shellcheck-py >/dev/null 2>&1 || true
  command -v shellcheck >/dev/null 2>&1 || note "shellcheck install failed (pip)"
fi

# actionlint (go) — lints .github/workflows. Its GitHub release binaries are
# unreachable under the default network policy, but the Go module proxy is
# open, so build it from source via `go install`.
if ! command -v actionlint >/dev/null 2>&1 && command -v go >/dev/null 2>&1; then
  GOBIN=/usr/local/bin go install github.com/rhysd/actionlint/cmd/actionlint@latest >/dev/null 2>&1 \
    || note "actionlint install failed (go install)"
fi

# Preflight summary — this lands in the session context.
missing=""
for tool in prettier xmllint markdownlint shellcheck actionlint; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
echo "Blurt web sandbox: no macOS toolchain — Swift build/tests/format run on CI (macos-26), the authority on green."
if [ -n "$missing" ]; then
  echo "Portable linters missing:${missing}. 'scripts/check.sh --portable' will skip them with a note."
else
  echo "Portable linters ready. Run 'scripts/check.sh --portable' to verify docs/site/scripts/workflow changes."
fi
exit 0
