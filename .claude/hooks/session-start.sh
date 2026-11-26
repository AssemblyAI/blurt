#!/bin/bash
# SessionStart hook: prepare a Claude Code on the web (Linux) sandbox.
#
# Blurt is macOS-only, so the Swift toolchain can't run here — but the portable
# checks (prettier / xmllint / markdownlint / shellcheck / actionlint / zizmor /
# shfmt / jscpd / release.test.sh) can. This hook installs the missing portable
# linters so `scripts/check.sh --portable` works, then prints a one-line preflight
# so the session starts knowing CI (macos-26) is the authority on green.
#
# Local (macOS) sessions are untouched: the hook exits immediately unless
# CLAUDE_CODE_REMOTE=true. Idempotent — every install is guarded on
# `command -v`, so a warm (cached) container skips straight through. Installs
# degrade to a note rather than failing the hook: the portable check skips
# absent tools the same way check.sh always has.
#
# SwiftLint is installed from its GitHub release, pinned by version and
# checksum, so `check.sh --portable` — and with it the push-gate hook — runs
# `swiftlint lint --strict` before every push, the check CI's `lint` job failed
# PRs on most often. swift-format is NOT installed: it comes with the Swift
# toolchain, which the sandbox lacks, so Swift formatting stays a CI concern on the web (the format-patch job
# publishes the fix); its PostToolUse hook no-ops cleanly when it is absent.
set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

note() { echo "session-start: $*"; }

# markdownlint-cli2 (npm) — check.sh's Markdown structural lint.
if ! command -v markdownlint-cli2 >/dev/null 2>&1; then
  npm install -g markdownlint-cli2 >/dev/null 2>&1 || note "markdownlint-cli2 install failed (npm)"
fi

# prettier (npm) — formatting authority for yml/yaml/md/html/css. Usually
# preinstalled in the web sandbox; this is a fallback.
if ! command -v prettier >/dev/null 2>&1; then
  npm install -g prettier >/dev/null 2>&1 || note "prettier install failed (npm)"
fi

# jscpd (npm) — check.sh's copy/paste gate, from tools/jscpd's lockfile (the one
# version pin; check.sh prefers that copy). The tokenizer decides what counts as a
# clone, so another release could disagree with CI.
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
jscpd_dir="$repo_root/tools/jscpd"
if [ ! -x "$jscpd_dir/node_modules/.bin/jscpd" ]; then
  npm ci --prefix "$jscpd_dir" >/dev/null 2>&1 || note "jscpd install failed (npm ci --prefix tools/jscpd)"
fi

# ruff, mypy, pytest and coverage.py (uv) — the evals' gates, from evals/uv.lock
# (check.sh prefers evals/.venv). uv itself comes from pip, and PyPI is reachable
# here, which is what lets the whole Python gate run in --portable.
python_bin="$repo_root/evals/.venv/bin"
python_tools="ruff mypy pytest coverage"
python_missing=""
for tool in $python_tools; do
  [ -x "$python_bin/$tool" ] || python_missing="$python_missing $tool"
done
if [ -n "$python_missing" ]; then
  if ! command -v uv >/dev/null 2>&1 && command -v pip3 >/dev/null 2>&1; then
    pip3 install --quiet uv >/dev/null 2>&1 || true
  fi
  uv sync --project "$repo_root/evals" --locked >/dev/null 2>&1 \
    || note "evals' Python tools install failed (uv sync --project evals --locked)"
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

# shfmt (go) — the formatting authority for scripts/*.sh, and a check.sh gate, so
# without it a web session pushes shell edits that CI can still fail on layout.
# Same channel as actionlint: GitHub release binaries are blocked, the Go module
# proxy is not.
if ! command -v shfmt >/dev/null 2>&1 && command -v go >/dev/null 2>&1; then
  GOBIN=/usr/local/bin go install mvdan.cc/sh/v3/cmd/shfmt@latest >/dev/null 2>&1 \
    || note "shfmt install failed (go install)"
fi

# zizmor (pip) — the security audit for .github/workflows. Published to PyPI as
# well as Homebrew, so pip is the one channel that works here; its GitHub release
# binaries are blocked by the same network policy that rules out actionlint's.
if ! command -v zizmor >/dev/null 2>&1 && command -v pip3 >/dev/null 2>&1; then
  pip3 install --quiet zizmor >/dev/null 2>&1 || true
  command -v zizmor >/dev/null 2>&1 || note "zizmor install failed (pip)"
fi

# SwiftLint (GitHub release) — `check.sh --portable` runs `swiftlint lint
# --strict` whenever it is on PATH, which makes the push gate catch the opt-in
# rules (type_contents_order, unused_parameter, async_without_await, …) that
# otherwise cost a ~37-minute CI run (#434). Pinned to the version CI's Homebrew
# installs, and checked against the release's checksum before it is unpacked:
# bump both together when CI's moves. The smoke test lints one file CI passes;
# a binary that can't (a missing SourceKit library, say) is removed rather than
# left to fail every push.
swiftlint_version="0.65.1"
swiftlint_sha256="caeed6f4a679c35539ffaf124f6c4ab4a8416917f7d8796279dc52b74026059d"
if ! command -v swiftlint >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
  swiftlint_tmp="$(mktemp -d "${TMPDIR:-/tmp}/swiftlint.XXXXXX")"
  swiftlint_url="https://github.com/realm/SwiftLint/releases/download/${swiftlint_version}/swiftlint_linux_amd64.zip"
  if curl -fsSL -m 180 -o "$swiftlint_tmp/swiftlint.zip" "$swiftlint_url" \
    && echo "$swiftlint_sha256  $swiftlint_tmp/swiftlint.zip" | shasum -a 256 -c --status - \
    && unzip -q -o "$swiftlint_tmp/swiftlint.zip" swiftlint -d "$swiftlint_tmp" \
    && install -m 0755 "$swiftlint_tmp/swiftlint" /usr/local/bin/swiftlint; then
    if ! (cd "$repo_root" && swiftlint lint --strict --quiet -- Sources/BlurtEngine/BlurtError.swift) >/dev/null 2>&1; then
      rm -f /usr/local/bin/swiftlint
      note "swiftlint ${swiftlint_version} installed but failed its smoke test; removed (CI still lints)"
    fi
  else
    note "swiftlint ${swiftlint_version} install failed (download, checksum or unzip)"
  fi
  rm -rf "$swiftlint_tmp"
fi

# Preflight summary — this lands in the session context.
missing=""
for tool in prettier xmllint markdownlint-cli2 shellcheck actionlint zizmor shfmt swiftlint; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
[ -x "$jscpd_dir/node_modules/.bin/jscpd" ] || missing="$missing jscpd"
for tool in $python_tools; do
  [ -x "$python_bin/$tool" ] || missing="$missing $tool"
done
echo "Blurt web sandbox: no macOS toolchain — Swift build/tests/format run on CI (macos-26), the authority on green."
if [ -n "$missing" ]; then
  echo "Portable linters missing:${missing}. 'scripts/check.sh --portable' will skip them with a note."
else
  echo "Portable linters ready. Run 'scripts/check.sh --portable' to verify docs/scripts/workflow changes."
fi
exit 0
