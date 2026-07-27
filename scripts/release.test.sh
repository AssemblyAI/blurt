#!/usr/bin/env bash
# Unit tests for the pure helpers in release.sh and release-lib.sh (pulled in
# transitively). Plain bash; no Mac/network dependencies. Run directly
# (scripts/release.test.sh) or via scripts/check.sh.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release.sh
source "$DIR/release.sh"

fails=0

# check <label> <expected> <actual>
check() {
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s — expected [%s], got [%s]\n' "$1" "$2" "$3"
    fails=1
  fi
}

# checkrc <expected-rc> <label> <cmd...>
checkrc() {
  local want="$1" label="$2"
  shift 2
  local got=0
  "$@" || got=$?
  check "$label" "$want" "$got"
}

# checktrue / checkfalse <label> <cmd...>
# For predicates whose contract is truthiness rather than a specific exit code —
# their callers use them in `if` / `&&`. `tag_exists_locally` is the reason these
# exist: it forwards git rev-parse's 128 for an unknown ref, which is false but
# is not 1, so checkrc would pin an exit code nothing depends on.
checktrue() {
  local label="$1"
  shift
  if "$@"; then printf '  ok   %s\n' "$label"; else
    printf '  FAIL %s — expected true, got exit %s\n' "$label" "$?"
    fails=1
  fi
}

checkfalse() {
  local label="$1"
  shift
  if "$@"; then
    printf '  FAIL %s — expected false, got exit 0\n' "$label"
    fails=1
  else printf '  ok   %s\n' "$label"; fi
}

# checkdie <label> <expected-substring> <cmd...>
# For helpers that fail by calling `die` (which exits). The command substitution
# runs them in a subshell, so the exit lands there rather than killing this
# runner. Asserts a nonzero exit AND that the operator-facing message names the
# problem — a guard that fails with an unhelpful message is half-broken.
checkdie() {
  local label="$1" want="$2"
  shift 2
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '  FAIL %s — expected a nonzero exit, got 0\n' "$label"
    fails=1
  elif [[ "$out" != *"$want"* ]]; then
    printf '  FAIL %s — expected output containing [%s], got [%s]\n' "$label" "$want" "$out"
    fails=1
  else
    printf '  ok   %s\n' "$label"
  fi
}

# Scratch git repo + files for the helpers that read a working tree or a
# project.yml. REPO_ROOT is what release-lib.sh's git helpers operate on; it is
# normally set inside release.sh's main(), which sourcing deliberately skips, so
# pointing it here can't touch the real checkout.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Kept beside the scratch repo rather than inside it: a stray fixture file in the
# working tree is exactly what require_clean_tree is supposed to object to.
FIXTURES="$TMP/fixtures"
SCRATCH_REPO="$TMP/repo"
mkdir -p "$FIXTURES" "$SCRATCH_REPO"
git -C "$SCRATCH_REPO" init --quiet
git -C "$SCRATCH_REPO" config user.email test@example.com
git -C "$SCRATCH_REPO" config user.name "Release Test"
: >"$SCRATCH_REPO/tracked"
git -C "$SCRATCH_REPO" add tracked
git -C "$SCRATCH_REPO" -c commit.gpgsign=false commit --quiet -m "init"
REPO_ROOT="$SCRATCH_REPO"

echo "== is_semver =="
checkrc 0 "0.1.6 is semver" is_semver 0.1.6
checkrc 0 "10.20.30 is semver" is_semver 10.20.30
checkrc 1 "0.1 is not semver" is_semver 0.1
checkrc 1 "v0.1.6 is not semver" is_semver v0.1.6
checkrc 1 "0.1.6-beta is not semver" is_semver 0.1.6-beta

echo "== version_gt =="
checkrc 0 "0.1.6 > 0.1.5" version_gt 0.1.6 0.1.5
checkrc 0 "0.2.0 > 0.1.9" version_gt 0.2.0 0.1.9
checkrc 0 "1.0.0 > 0.9.9" version_gt 1.0.0 0.9.9
checkrc 1 "0.1.5 not > 0.1.5" version_gt 0.1.5 0.1.5
checkrc 1 "0.1.4 not > 0.1.5" version_gt 0.1.4 0.1.5
# The lexical trap: "0.1.10" sorts BEFORE "0.1.9" as a string, so a comparison
# that lost `sort -V` would call the tenth patch older than the ninth — and
# decide_run would refuse the release as "behind main".
checkrc 0 "0.1.10 > 0.1.9 (numeric, not lexical)" version_gt 0.1.10 0.1.9
checkrc 1 "0.1.9 not > 0.1.10" version_gt 0.1.9 0.1.10

echo "== parse_yaml_scalar =="
check "reads an arbitrary key" "Blurt" "$(printf 'name: Blurt\n' | parse_yaml_scalar name)"
check "strips double quotes" "Blurt" "$(printf '        name: "Blurt"\n' | parse_yaml_scalar name)"
check "strips single quotes" "Blurt" "$(printf "        name: 'Blurt'\n" | parse_yaml_scalar name)"
check "absent key -> empty" "" "$(printf 'other: 1\n' | parse_yaml_scalar name)"

echo "== parse_short_version =="
check "parses version" "0.1.5" \
  "$(printf '        CFBundleVersion: "6"\n        CFBundleShortVersionString: "0.1.5"\n' | parse_short_version)"
check "takes first match only" "0.1.5" \
  "$(printf '        CFBundleShortVersionString: "0.1.5"\n        CFBundleShortVersionString: "9.9.9"\n' | parse_short_version)"
check "strips single quotes" "1.2.3" \
  "$(printf "        CFBundleShortVersionString: '1.2.3'\n" | parse_short_version)"

# Pins what the whole-field key match (`$1 == key`) buys over the old unanchored
# substring regex. Note `CFBundleVersionSomethingElse` was NOT a real hazard --
# the old `/CFBundleVersion:/` already required the colon. The two cases that did
# break are a key with a *prefix* and a commented-out key (where the old awk
# printed `$2`, i.e. the literal key name, as the version).
echo "== parse_bundle_version =="
check "parses build number" "6" \
  "$(printf '        CFBundleShortVersionString: "0.1.5"\n        CFBundleVersion: "6"\n' | parse_bundle_version)"
check "ignores a prefixed key" "32" \
  "$(printf '        MyCFBundleVersion: "99"\n        CFBundleVersion: "32"\n' | parse_bundle_version)"
check "ignores a commented-out key" "32" \
  "$(printf '        # CFBundleVersion: "99"\n        CFBundleVersion: "32"\n' | parse_bundle_version)"
check "ignores a longer key sharing the prefix" "32" \
  "$(printf '        CFBundleVersionSomethingElse: "99"\n        CFBundleVersion: "32"\n' | parse_bundle_version)"

echo "== parse_build_info_git_sha =="
check "parses build provenance sha" "0123456789abcdef0123456789abcdef01234567" \
  "$(printf 'Blurt 0.1.7\nbuilt: today\ngit:          0123456789abcdef0123456789abcdef01234567 (0123456)\n' | parse_build_info_git_sha)"
check "missing build provenance sha -> empty" "" \
  "$(printf 'Blurt 0.1.7\nbuilt: today\n' | parse_build_info_git_sha)"

echo "== decide_run =="
check "equal -> publish" "publish" "$(decide_run 0.1.6 0.1.6)"
check "ahead -> bump" "bump" "$(decide_run 0.1.5 0.1.6)"
checkrc 1 "behind -> error" decide_run 0.1.6 0.1.5

echo "== next_patch =="
check "0.1.5 -> 0.1.6" "0.1.6" "$(next_patch 0.1.5)"
check "0.1.9 -> 0.1.10" "0.1.10" "$(next_patch 0.1.9)"
check "1.2.3 -> 1.2.4" "1.2.4" "$(next_patch 1.2.3)"
checkrc 1 "rejects non-semver" next_patch 0.1

echo "== default_target =="
# main ahead of the latest tag -> a merged bump awaits publishing -> target it.
check "main ahead of tag -> that version" "0.1.6" "$(default_target 0.1.6 0.1.5)"
# main == latest tag -> nothing pending -> start the next patch.
check "main == tag -> next patch" "0.1.6" "$(default_target 0.1.5 0.1.5)"
# no tags yet -> start the next patch from main.
check "no tags -> next patch" "0.1.6" "$(default_target 0.1.5 '')"

echo "== identity_listed =="
printf '  1) 640A7F5A9754400D4A0491E7A6FB30542D907806 "Developer ID Application: Alexander Kroman (Y54ZB9JF63)"\n' \
  | identity_listed 640A7F5A9754400D4A0491E7A6FB30542D907806
check "present -> rc 0" "0" "$?"
printf '  1) 0000000000000000000000000000000000000000 "Some Other Identity"\n' \
  | identity_listed 640A7F5A9754400D4A0491E7A6FB30542D907806
check "absent -> rc 1" "1" "$?"

echo "== sha_from_sums =="
check "finds hash by name" "abc123" \
  "$(printf 'abc123  Blurt-0.1.5.dmg\ndef456  Blurt-0.1.5.app.dSYM.zip\n' | sha_from_sums Blurt-0.1.5.dmg)"
check "handles binary-mode star" "abc123" \
  "$(printf 'abc123 *Blurt-0.1.5.dmg\n' | sha_from_sums Blurt-0.1.5.dmg)"
check "missing name -> empty" "" \
  "$(printf 'abc123  Blurt-0.1.5.dmg\n' | sha_from_sums nope.dmg)"
# The shape release-publish.sh actually reads: the one notarized image is listed
# under both its archival and its stable name, and the requested one is not the
# first row. Selecting by position rather than by name would verify the published
# Blurt.dmg against the other entry's digest — a mismatch that reads as "the
# upload is corrupt" on a perfectly good release.
check "selects by name when both published names are listed" "stable" \
  "$(printf 'archival  Blurt-0.1.5.dmg\nstable  Blurt.dmg\n' | sha_from_sums Blurt.dmg)"

echo "== require_tools =="
checkrc 0 "tools on PATH pass" require_tools sh awk
checkdie "a missing tool is named" "missing required tool: blurt-no-such-tool" \
  require_tools blurt-no-such-tool
checkdie "the first missing tool of several is named" "missing required tool: blurt-no-such-tool" \
  require_tools sh blurt-no-such-tool awk
# The --hint arm exists so a tool that isn't preinstalled tells the operator how
# to get it; it must be consumed as an option, not treated as a tool name.
checkdie "--hint text is appended to the failure" "(brew install create-dmg if needed)" \
  require_tools --hint='brew install create-dmg if needed' blurt-no-such-tool
checkrc 0 "--hint alone doesn't become a required tool" \
  require_tools --hint='some hint' sh

echo "== require_project_version =="
printf '        CFBundleVersion: "6"\n        CFBundleShortVersionString: "0.1.5"\n' >"$FIXTURES/project.yml"
check "reads the version out of a project.yml" "0.1.5" "$(require_project_version "$FIXTURES/project.yml")"
printf 'name: Blurt\n' >"$FIXTURES/no-version.yml"
# Every release step gates on this read. An unparseable project.yml must stop the
# run, not yield an empty version that would tag "v" and build the wrong artifact.
checkdie "an unparseable project.yml stops the run" "could not parse CFBundleShortVersionString" \
  require_project_version "$FIXTURES/no-version.yml"
checkdie "a missing project.yml stops the run" "could not parse CFBundleShortVersionString" \
  require_project_version "$FIXTURES/absent.yml"

echo "== require_clean_tree =="
checkrc 0 "a clean tree passes" require_clean_tree "publishing"
printf 'dirty\n' >"$SCRATCH_REPO/tracked"
checkdie "a dirty tree stops the run, naming the action" \
  "commit or stash before publishing" require_clean_tree "publishing"
# An untracked file counts too: release-build.sh's provenance records HEAD, so
# anything uncommitted in the tree would ship unrecorded.
git -C "$SCRATCH_REPO" checkout --quiet -- tracked
printf 'stray\n' >"$SCRATCH_REPO/untracked"
checkdie "an untracked file also stops the run" "working tree dirty" require_clean_tree "building"
rm -f "$SCRATCH_REPO/untracked"
checkrc 0 "the tree is clean again once the stray is gone" require_clean_tree "publishing"

echo "== tag_exists_locally =="
# release-bump.sh refuses to reuse a version whose tag already exists, so a
# false negative here would let a bump PR target an already-released version.
checkfalse "an unknown tag is absent" tag_exists_locally v9.9.9
git -C "$SCRATCH_REPO" tag v9.9.9
checktrue "a created tag is found" tag_exists_locally v9.9.9
git -C "$SCRATCH_REPO" tag -d v9.9.9 >/dev/null

echo "== latest_release_tag =="
check "no tags -> empty" "" "$(latest_release_tag)"
git -C "$SCRATCH_REPO" tag v0.1.9
git -C "$SCRATCH_REPO" tag v0.1.10
# Same lexical trap as version_gt, on the other side of the release decision:
# picking "0.1.9" here would make default_target propose a version already
# published.
check "picks the numerically highest, not the lexically last" "0.1.10" "$(latest_release_tag)"
git -C "$SCRATCH_REPO" tag v0.2.0
check "orders across minor versions" "0.2.0" "$(latest_release_tag)"
# Only vX.Y.Z tags are releases. A prerelease or a moving pointer must not be
# read as the latest published version.
git -C "$SCRATCH_REPO" tag v1.0.0-rc1
git -C "$SCRATCH_REPO" tag nightly
git -C "$SCRATCH_REPO" tag v3.0
check "ignores prerelease, non-version, and short tags" "0.2.0" "$(latest_release_tag)"

echo "== CLI preflight (subprocess) =="
# These run main() in a child process. Arg validation happens before any git /
# network call, so invalid input dies cleanly with no side effects. (A bare
# no-arg invocation is intentionally NOT tested here — it now proceeds to fetch
# origin and would perform real work.)
checkrc 1 "bad format -> error" bash "$DIR/release.sh" 1.2
checkrc 1 "extra args -> usage error" bash "$DIR/release.sh" 0.1.6 0.1.7

if [ "$fails" -eq 0 ]; then
  echo "release.sh: all tests passed"
else
  echo "release.sh: TESTS FAILED"
fi
exit "$fails"
