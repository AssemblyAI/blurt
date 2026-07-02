#!/usr/bin/env bash
# Single-command release orchestrator. Resumable; wraps the three release
# scripts and bridges the protected-main bump PR.
#
# Releases normally run in CI: the `release` workflow
# (.github/workflows/release.yml) drives these same stages on a macos-26
# runner — dispatch it to open the bump PR, and merging that PR builds and
# publishes automatically. This script is the local path: CI reuses its bump
# stage and decision helpers, and running it on a Mac remains a full fallback.
#
# Usage: scripts/release.sh [X.Y.Z]
#
#   With no version, targets the next step of releasing automatically: if a
#   merged bump isn't published yet, it publishes that; otherwise it starts the
#   next patch (latest published vX.Y.Z + 1). Pass X.Y.Z to target a specific
#   version (e.g. a minor/major bump).
#
#   Run 1 (bump not yet on main): opens a release/vX.Y.Z bump PR, then stops.
#   Run 2 (bump merged):          builds + notarizes the DMG, then tags,
#                                 pushes, and publishes the GitHub Release.
#                                 (When run locally — in CI the publish job
#                                 fires on the bump PR's merge to main.)

# Shared logging + pure version helpers (is_semver, version_gt,
# parse_short_version, parse_build_info_git_sha) live in release-lib.sh so all
# the release scripts share one definition.
# shellcheck source=scripts/release-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release-lib.sh"

# --- pure helpers (sourced by scripts/release.test.sh; keep side-effect-free) ---

# Decide the run given main's current version ($1) and the target ($2).
# Echoes "publish" (target already on main) or "bump" (target is ahead).
# Returns nonzero with no output when the target is behind main's version.
decide_run() {
  local main_v="$1" target="$2"
  if [ "$target" = "$main_v" ]; then
    echo publish
    return 0
  fi
  if version_gt "$target" "$main_v"; then
    echo bump
    return 0
  fi
  return 1
}

# Echo the next patch version after $1 (X.Y.Z -> X.Y.(Z+1)).
# Returns nonzero with no output if $1 is not X.Y.Z.
next_patch() {
  is_semver "$1" || return 1
  local major minor patch
  IFS=. read -r major minor patch <<<"$1"
  printf '%s.%s.%s\n' "$major" "$minor" "$((patch + 1))"
}

# Echo the default release target when no version is given on the command line,
# derived from main's current version ($1) and the latest published release tag
# ($2, may be empty):
#  - main ahead of the latest tag -> a bump already merged but isn't published
#    yet, so target that same version (decide_run will pick "publish" -> resume).
#  - otherwise -> start the next patch (decide_run will pick "bump").
# Returns nonzero if main's version is not X.Y.Z.
default_target() {
  local main_v="$1" latest_tag="$2"
  if [ -n "$latest_tag" ] && version_gt "$main_v" "$latest_tag"; then
    echo "$main_v"
  else
    next_patch "$main_v"
  fi
}

# --- IO helpers (side-effecting; verified by a real release, not unit tests) ---

# Current version on origin/main, without disturbing the working tree.
remote_main_version() {
  git -C "$REPO_ROOT" show origin/main:App/Blurt/project.yml | parse_short_version
}

# Highest published release tag (vX.Y.Z) with the leading "v" stripped; empty if
# there are none. Assumes tags are fetched (main runs git fetch --tags first).
latest_release_tag() {
  git -C "$REPO_ROOT" tag --list 'v[0-9]*' \
    | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' \
    | sort -V | tail -n1
}

# True if a complete, stapled release exists for $1 — i.e. everything
# release-publish.sh requires (DMG + dSYM zip + checksums), not just the DMG.
dmg_already_built() {
  local dmg="$BUILD_ROOT/Blurt-$1.dmg"
  local build_info="$BUILD_ROOT/build-info.txt"
  [ -f "$dmg" ] || return 1
  [ -f "$BUILD_ROOT/Blurt-$1.app.dSYM.zip" ] || return 1
  [ -f "$BUILD_ROOT/SHA256SUMS" ] || return 1
  [ -f "$build_info" ] || return 1

  local built_sha head_sha
  built_sha="$(parse_build_info_git_sha <"$build_info")"
  [ -n "$built_sha" ] || return 1
  head_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)" || return 1
  [ "$built_sha" = "$head_sha" ] || return 1

  xcrun stapler validate "$dmg" >/dev/null 2>&1
}

# Run 1: open the bump PR, then stop. Idempotent + resumable: keys on actual
# PR existence (not just the branch), reuses a partially-created branch, skips
# an already-applied bump, and restores main if anything fails mid-run so the
# operator is never stranded on the release branch.
run_bump_pr() {
  local version="$1" branch="release/v$1"

  # Already have an open PR? Remind and stop.
  local existing_pr
  existing_pr="$(cd "$REPO_ROOT" \
    && gh pr list --head "$branch" --state open --json url -q '.[0].url' 2>/dev/null || true)"
  if [ -n "$existing_pr" ]; then
    info "PR already open: $existing_pr"
    info "Merge it — the release workflow builds + publishes v$version on merge"
    info "(local fallback: scripts/release.sh $version)"
    git -C "$REPO_ROOT" checkout main >/dev/null 2>&1 || true
    exit 0
  fi

  # On any failure past this point, return to main so we never strand the
  # operator on a half-built release branch (best-effort; a dirty tree may
  # block the checkout, which is fine — the underlying error still surfaces).
  trap 'git -C "$REPO_ROOT" checkout main >/dev/null 2>&1 || true' ERR

  step "Bump branch"
  if git -C "$REPO_ROOT" rev-parse --verify "$branch" >/dev/null 2>&1; then
    git -C "$REPO_ROOT" checkout "$branch"
  elif git -C "$REPO_ROOT" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    git -C "$REPO_ROOT" checkout -b "$branch" "origin/$branch"
  else
    git -C "$REPO_ROOT" checkout -b "$branch" origin/main
  fi

  # Skip the bump if a prior run already applied it on this branch.
  local branch_v
  branch_v="$(parse_short_version <"$REPO_ROOT/App/Blurt/project.yml")"
  if [ "$branch_v" = "$version" ]; then
    info "branch already bumped to $version — skipping bump"
  else
    step "Bump version"
    "$REPO_ROOT/scripts/release-bump.sh" "$version"
  fi

  step "Push + open PR"
  git -C "$REPO_ROOT" push -u origin "$branch"
  (cd "$REPO_ROOT" && gh pr create \
    --head "$branch" --base main \
    --title "chore: release v$version" \
    --body "Version bump for v$version. Merging triggers the \`release\` workflow, which builds, notarizes, and publishes the GitHub Release automatically (local fallback: \`scripts/release.sh $version\`).")

  trap - ERR
  # Return to main so the operator is never left sitting on the release branch
  # (the bump is committed + pushed; main is where the next run resumes from).
  git -C "$REPO_ROOT" checkout main >/dev/null 2>&1 \
    || info "note: could not switch back to main — you're on $branch"
  step "Next"
  info "PR opened. Merge it — the release workflow builds + publishes v$version on merge"
  info "(local fallback: scripts/release.sh $version)"
}

# Run 2: build (skip if already built) + publish.
run_build_publish() {
  local version="$1"

  step "Sync main"
  git -C "$REPO_ROOT" checkout main
  git -C "$REPO_ROOT" pull --ff-only

  local main_v
  main_v="$(parse_short_version <"$REPO_ROOT/App/Blurt/project.yml")"
  [ "$main_v" = "$version" ] \
    || die "main is at $main_v, expected $version after merge — pull main and retry"

  step "Build"
  if dmg_already_built "$version"; then
    info "DMG for $version already built + stapled — skipping build"
  else
    "$REPO_ROOT/scripts/release-build.sh"
  fi

  # Install the notarized build locally so the publish prompt below doubles as
  # a "tested it, ship it" gate — test the real artifact before it's published.
  step "Install for local testing"
  "$REPO_ROOT/scripts/release-install.sh"

  step "Publish"
  "$REPO_ROOT/scripts/release-publish.sh"
}

main() {
  # Inside main (not file-scope) so release.test.sh can source the helpers
  # without inheriting set -e and aborting the test runner.
  set -euo pipefail
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  BUILD_ROOT="$REPO_ROOT/build/release"

  [ $# -le 1 ] || die "usage: $(basename "$0") [X.Y.Z]"
  local version="${1:-}"
  if [ -n "$version" ]; then
    is_semver "$version" || die "version must be X.Y.Z (got: $version)"
  fi

  for cmd in git gh xcodegen awk; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required tool: $cmd"
  done

  require_clean_tree "releasing"

  step "Fetch origin"
  git -C "$REPO_ROOT" fetch origin --tags --quiet

  local main_v run
  main_v="$(remote_main_version)"
  [ -n "$main_v" ] || die "could not read version from origin/main"

  # No version given: default to the next step of releasing — publish a merged
  # bump that isn't tagged yet, otherwise start the next patch.
  if [ -z "$version" ]; then
    version="$(default_target "$main_v" "$(latest_release_tag)")" \
      || die "could not derive a default target from origin/main ($main_v)"
    info "no version given — defaulting to $version"
  fi
  info "origin/main is at $main_v; target $version"

  run="$(decide_run "$main_v" "$version")" \
    || die "target $version is behind origin/main ($main_v)"

  case "$run" in
    bump) run_bump_pr "$version" ;;
    publish) run_build_publish "$version" ;;
  esac
}

# Run only when executed, not when sourced by the test suite.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
