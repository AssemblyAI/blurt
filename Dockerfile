# Portable-check environment for Blurt.
#
# Blurt is macOS-only (AppKit + AVFoundation), so this image cannot build the
# app or run the Swift tests — macos-26 CI stays the authority on green. What
# it CAN do is package the platform-independent linters and run
# `scripts/check.sh --portable` (repo-integrity guards, actionlint, prettier,
# xmllint, markdownlint, shellcheck, release.test.sh) in a reproducible Linux
# container, the same subset a web sandbox runs.
#
# Build and run via scripts/docker-check.sh — the `docker` job in
# .github/workflows/check.yml runs exactly that script.
FROM node:22-bookworm-slim

# git: check.sh discovers files via `git ls-files`.
# libxml2-utils: xmllint (XML well-formedness, e.g. the Pages sitemap).
# curl/ca-certificates/xz-utils: fetch the shellcheck/actionlint release binaries.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    libxml2-utils \
    xz-utils \
  && rm -rf /var/lib/apt/lists/*

# prettier / markdownlint: latest, matching the brew-latest behavior of the
# macOS CI job so the two runs can't disagree about formatting rules.
RUN npm install -g prettier markdownlint-cli

# shellcheck: pinned release binary, NOT Debian's package — bookworm ships an
# old shellcheck that flags SC2015 info findings CI's newer brew build accepts,
# a false red (same reason the web-sandbox hook installs shellcheck-py).
ARG SHELLCHECK_VERSION=v0.10.0
RUN arch="$(dpkg --print-architecture)" \
  && case "$arch" in \
    amd64) sc_arch=x86_64 ;; \
    arm64) sc_arch=aarch64 ;; \
    *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
  esac \
  && curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.${sc_arch}.tar.xz" \
    | tar -xJ -C /usr/local/bin --strip-components=1 "shellcheck-${SHELLCHECK_VERSION}/shellcheck"

# actionlint: pinned release binary (lints .github/workflows).
ARG ACTIONLINT_VERSION=1.7.7
RUN arch="$(dpkg --print-architecture)" \
  && curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${arch}.tar.gz" \
    | tar -xz -C /usr/local/bin actionlint

# The repo is bind-mounted read-only at /work (see scripts/docker-check.sh).
# It is owned by the host user while the container runs as root, so git refuses
# to touch it without the safe.directory grant.
WORKDIR /work
RUN git config --global --add safe.directory /work

CMD ["scripts/check.sh", "--portable"]
