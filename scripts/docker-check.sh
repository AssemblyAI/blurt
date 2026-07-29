#!/bin/bash
# Build the portable-check Docker image (Dockerfile at the repo root) and run
# `scripts/check.sh --portable` inside it. One entry point shared by local use
# and the `docker` job in .github/workflows/check.yml, so the two can't drift.
#
# The repo is bind-mounted read-only: the portable checks only read the tree
# (release.test.sh writes to the container's own /tmp), so nothing in the
# container can dirty the checkout.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE=blurt-portable-check

echo "==> docker build ($IMAGE)"
docker build -t "$IMAGE" "$REPO_ROOT"

echo "==> docker run (scripts/check.sh --portable)"
docker run --rm -v "$REPO_ROOT:/work:ro" "$IMAGE"
