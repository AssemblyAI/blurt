#!/usr/bin/env bash
# Shared helpers for the repo's bash scripts — the release pipeline (release.sh,
# release-bump.sh, release-build.sh, release-install.sh, release-publish.sh) plus
# dev-build.sh, which reuses the logging and tool-preflight helpers. Sourced,
# never executed. Everything here must stay side-effect-free at source time —
# release.test.sh sources release.sh (which sources this) to unit-test the
# pure helpers.

# --- logging ---

info() { printf '\033[34m▸\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die() {
  printf '\033[31m✗\033[0m %s\n' "$*" >&2
  exit 1
}

# --- shared guards (need REPO_ROOT set by the sourcing script) ---

# Die unless every named command is on PATH. The one definition of the
# required-tool preflight each release step opens with; pass the tools it needs
# (e.g. `require_tools xcrun hdiutil codesign ditto awk`). An optional leading
# `--hint=<text>` is appended to the failure message for tools that aren't
# preinstalled (e.g. `--hint='brew install create-dmg if needed'`).
require_tools() {
  local cmd hint=""
  case "${1:-}" in
    --hint=*)
      hint=" (${1#--hint=})"
      shift
      ;;
  esac
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required tool: $cmd$hint"
  done
}

# Set the PRETTY array every xcodebuild caller pipes through: `xcbeautify --quiet`
# when installed, `cat` otherwise. The one definition, because four scripts had
# copied it and two of the copies had already lost the "not installed" note — so a
# developer without xcbeautify got raw logs from those with no explanation. Use as:
#   pretty_xcodebuild
#   xcodebuild … | "${PRETTY[@]}"
# shellcheck disable=SC2034  # PRETTY is read by the sourcing script, not here.
pretty_xcodebuild() {
  if command -v xcbeautify >/dev/null 2>&1; then
    PRETTY=(xcbeautify --quiet)
  else
    PRETTY=(cat)
    info "xcbeautify not installed; using raw output (brew install xcbeautify)"
  fi
}

# Die unless the git working tree is clean; $1 names the action for the message
# (e.g. "publishing" -> "… commit or stash before publishing").
require_clean_tree() {
  [ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] \
    || die "working tree dirty — commit or stash before ${1:-continuing}"
}

# Echo CFBundleShortVersionString read from the project.yml at $1, dying when
# it can't be parsed. Call as a PLAIN assignment:
#   VERSION="$(require_project_version "$path")"
# so the die inside the substitution fails the assignment under `set -e`. Do NOT
# write `local v="$(require_project_version …)"` — `local`/`declare`/`export`
# swallow the substitution's exit status, so the die prints but execution
# continues with an empty value. Declare first, assign on the next line.
require_project_version() {
  local version
  version="$(parse_short_version <"$1")"
  [ -n "$version" ] || die "could not parse CFBundleShortVersionString from $1"
  printf '%s\n' "$version"
}

# True if tag $1 (e.g. "v1.2.3") exists in the local repo.
tag_exists_locally() {
  git -C "$REPO_ROOT" rev-parse "$1" >/dev/null 2>&1
}

# True if tag $1 exists on origin.
tag_exists_on_origin() {
  git -C "$REPO_ROOT" ls-remote --tags origin "refs/tags/$1" 2>/dev/null | grep -q .
}

# True if codesigning identity $1 (a SHA-1 hash) appears in the
# `security find-identity -v -p codesigning` output piped on stdin.
identity_listed() {
  grep -qF -- "$1"
}

# Signer-pin: die unless codesigned artifact $1 is signed by EXACTLY the expected
# leaf-certificate SHA-256 fingerprint ($2) and Team ID ($3). Signing with an
# explicit identity hash already selects the cert, but this verifies the
# *produced* artifact after the fact — so a release built/signed with any other
# (even otherwise-valid) Developer ID fails closed here instead of being
# published. SHA-256 (not the SHA-1 identity hash `security` reports) is used for
# the comparison so the pin doesn't rest on a weakened digest. Needs codesign +
# openssl.
verify_signer() {
  local artifact="$1" want_sha256="$2" want_team="$3"

  local got_team
  got_team="$(codesign -dvv "$artifact" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [ "$got_team" = "$want_team" ] \
    || die "signer-pin: $artifact has TeamIdentifier '$got_team', expected '$want_team'"

  local tmp
  tmp="$(mktemp -d)" || die "signer-pin: mktemp failed"
  # --extract-certificates writes <prefix>0 (leaf), <prefix>1, … as DER.
  codesign -d --extract-certificates="$tmp/cert" "$artifact" >/dev/null 2>&1 \
    || { rm -rf "$tmp"; die "signer-pin: could not extract certificates from $artifact"; }
  local got_sha
  got_sha="$(openssl x509 -inform DER -in "$tmp/cert0" -noout -fingerprint -sha256 2>/dev/null \
    | sed -n 's/.*Fingerprint=//p' | tr -d ': ' | tr '[:lower:]' '[:upper:]')"
  rm -rf "$tmp"
  [ -n "$got_sha" ] || die "signer-pin: could not fingerprint leaf cert of $artifact"

  [ "$got_sha" = "$(printf '%s' "$want_sha256" | tr '[:lower:]' '[:upper:]')" ] \
    || die "signer-pin: $artifact leaf cert SHA-256 $got_sha != expected $want_sha256"
  info "signer-pin ok: $(basename "$artifact") — leaf sha256 $got_sha, team $got_team"
}

# --- pure version helpers (unit-tested by scripts/release.test.sh) ---

# True if $1 looks like X.Y.Z (digits only).
is_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# True if version $1 is strictly greater than version $2 (semver-ordered).
version_gt() {
  [ "$1" != "$2" ] || return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# Read the scalar value of YAML key $1 from content on stdin, stripping single or
# double quotes. Matches the key as a whole awk field ($1 on an indented line is
# the key), which the previous unanchored `/key:/` regex did not: `MyCFBundleVersion:`
# matched and returned the wrong value, and a commented-out `# CFBundleVersion:`
# matched with `$2` being the key name itself. (A longer key sharing the prefix,
# like `CFBundleVersionSomethingElse:`, was never a hazard — the old regex already
# required the colon.) All three are pinned in release.test.sh.
parse_yaml_scalar() {
  awk -v key="$1:" '$1 == key {gsub(/["'"'"']/, "", $2); print $2; exit}'
}

# Read CFBundleShortVersionString from project.yml content on stdin. The one
# definition of the version-read rule every release script gates on.
parse_short_version() {
  parse_yaml_scalar CFBundleShortVersionString
}

# Read CFBundleVersion (the integer build number) from project.yml on stdin.
parse_bundle_version() {
  parse_yaml_scalar CFBundleVersion
}

# Read the full commit SHA from build-info.txt content on stdin.
parse_build_info_git_sha() {
  awk '/^git:[[:space:]]+/ {print $2; exit}'
}

# Echo the SHA-256 hex for filename $1 from SHA256SUMS content on stdin (shasum's
# "<hash>  <name>" format; a leading "*" binary marker on the name is tolerated).
# Empty output if the name isn't listed.
sha_from_sums() {
  awk -v name="$1" '{ f = $2; sub(/^\*/, "", f); if (f == name) { print $1; exit } }'
}

# Echo the SHA-256 hex of the file at $1 — the digest form `sha_from_sums` reads
# back out of SHA256SUMS. One definition so the algorithm and the field extraction
# can't drift between the build that publishes a digest and the publish step that
# compares the uploaded artifact against it.
sha256_of_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}
