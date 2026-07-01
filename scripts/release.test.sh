#!/usr/bin/env bash
# Unit tests for the pure helpers in release.sh. Plain bash; no Mac/network
# dependencies. Run directly (scripts/release.test.sh) or via scripts/check.sh.
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

echo "== parse_short_version =="
check "parses version" "0.1.5" \
  "$(printf '        CFBundleVersion: "6"\n        CFBundleShortVersionString: "0.1.5"\n' | parse_short_version)"
check "takes first match only" "0.1.5" \
  "$(printf '        CFBundleShortVersionString: "0.1.5"\n        CFBundleShortVersionString: "9.9.9"\n' | parse_short_version)"

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
