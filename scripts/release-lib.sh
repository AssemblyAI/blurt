#!/usr/bin/env bash
# Shared helpers for the repo's bash scripts — the release pipeline (release.sh,
# release-bump.sh, release-build.sh, release-install.sh, release-publish.sh,
# release-stage.sh) plus
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

# Highest published release tag (vX.Y.Z) with the leading "v" stripped; empty if
# there are none. Assumes tags are fetched — a shallow clone has none, so a
# caller that gates on this must check out with fetch-depth: 0.
latest_release_tag() {
  release_versions | tail -n1
}

# Highest release tag strictly below version $1 ("v" stripped); empty if none.
# The release a build's changelog is measured from — not `latest_release_tag`,
# which on a republish is the version being rebuilt. Same fetch-depth caveat.
previous_release_tag() {
  local v prev=""
  while IFS= read -r v; do
    if version_gt "$1" "$v"; then prev="$v"; fi
  done < <(release_versions)
  printf '%s\n' "$prev"
}

# Every vX.Y.Z tag with the "v" stripped, oldest first. Anything else — a
# prerelease, sparkle-staging, a moving pointer — is not a release.
release_versions() {
  git -C "$REPO_ROOT" tag --list 'v[0-9]*' \
    | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' \
    | sort -V
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
    || {
      rm -rf "$tmp"
      die "signer-pin: could not extract certificates from $artifact"
    }
  local got_sha
  got_sha="$(openssl x509 -inform DER -in "$tmp/cert0" -noout -fingerprint -sha256 2>/dev/null \
    | sed -n 's/.*Fingerprint=//p' | tr -d ': ' | tr '[:lower:]' '[:upper:]')"
  rm -rf "$tmp"
  [ -n "$got_sha" ] || die "signer-pin: could not fingerprint leaf cert of $artifact"

  [ "$got_sha" = "$(printf '%s' "$want_sha256" | tr '[:lower:]' '[:upper:]')" ] \
    || die "signer-pin: $artifact leaf cert SHA-256 $got_sha != expected $want_sha256"
  info "signer-pin ok: $(basename "$artifact") — leaf sha256 $got_sha, team $got_team"
}

# --- release-target resolution (pure; unit-tested by scripts/release.test.sh) ---
#
# Which version a release is aiming at, and whether that means bumping or
# publishing. `release-bump.yml` uses these to resolve an omitted version input,
# so the same rules decide it whether a release is started from the workflow or
# reasoned about by hand.

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

# Echo the default release target when no version was given, derived from main's
# current version ($1) and the latest release tag ($2, may be empty):
#  - main ahead of the latest tag -> a bump already merged but isn't published
#    yet, so target that same version (decide_run will pick "publish").
#  - otherwise -> start the next patch (decide_run will pick "bump").
# Returns nonzero if main's version is not X.Y.Z.
#
# Note it takes the next patch, not the next UNUSED patch: an abandoned release
# can leave a tag with no release behind it, and that version is burned. The
# caller is expected to fail loudly on the collision rather than silently
# skipping ahead — quietly renumbering a release is worse than stopping.
default_target() {
  local main_v="$1" latest_tag="$2"
  if [ -n "$latest_tag" ] && version_gt "$main_v" "$latest_tag"; then
    echo "$main_v"
  else
    next_patch "$main_v"
  fi
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

# Read the build channel (`release` or `staging`) from build-info.txt content on
# stdin. Empty for a build-info written before channels existed, which callers
# treat as `release`.
parse_build_info_channel() {
  awk '/^channel:[[:space:]]+/ {print $2; exit}'
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

# --- Sparkle ---

# Read the Sparkle public EdDSA key (the SPARKLE_PUBLIC_ED_KEY build setting)
# from project.yml content on stdin.
parse_sparkle_public_key() {
  parse_yaml_scalar SPARKLE_PUBLIC_ED_KEY
}

# True when $1 is a usable Sparkle public key rather than empty or the
# placeholder project.yml ships with before a key pair exists. Shipping the
# placeholder would build an app that rejects every future update, so the
# release refuses to start until a real key is in place.
sparkle_key_is_set() {
  case "$1" in
    "" | REPLACE_WITH_*) return 1 ;;
  esac
}

# Pull one attribute out of `sign_update`'s output on stdin, which is a fragment
# of enclosure attributes: sparkle:edSignature="<b64>" length="<bytes>".
# $1 is the attribute name (`sparkle:edSignature` or `length`); empty output if
# it's absent.
parse_sign_update_attr() {
  sed -n "s/.*$1=\"\([^\"]*\)\".*/\1/p" | head -n 1
}

# Where the updater looks, per build channel. `release` is the feed every
# shipped copy polls: /latest/download/ follows whichever release is marked
# latest, so it moves only when release-publish.sh flips one live. `staging` is
# the rehearsal feed (RELEASE.md → Rehearsing an update): a fixed prerelease
# that /latest never resolves to, so nothing staged can reach a shipped copy.
BLURT_RELEASES_URL="https://github.com/AssemblyAI/blurt/releases"
SPARKLE_STAGING_TAG="sparkle-staging"

# Echo the appcast URL for channel $1 (`release` or `staging`).
sparkle_feed_url() {
  case "$1" in
    release) printf '%s\n' "$BLURT_RELEASES_URL/latest/download/appcast.xml" ;;
    staging) printf '%s\n' "$BLURT_RELEASES_URL/download/$SPARKLE_STAGING_TAG/appcast.xml" ;;
    *) die "unknown Sparkle channel: $1" ;;
  esac
}

# Echo the DMG URL the appcast's enclosure names, for channel $1 and version $2.
# A release names its own versioned asset; staging names the one on the
# staging prerelease, which each staged build overwrites.
sparkle_enclosure_url() {
  case "$1" in
    release) printf '%s\n' "$BLURT_RELEASES_URL/download/v$2/Blurt-$2.dmg" ;;
    staging) printf '%s\n' "$BLURT_RELEASES_URL/download/$SPARKLE_STAGING_TAG/Blurt-$2.dmg" ;;
    *) die "unknown Sparkle channel: $1" ;;
  esac
}

# Turn commit subjects on stdin (newest first, as `git log --format=%s` prints
# them) into the Markdown bullet list the update window shows. Drops what a user
# has no use for: conventional-commit housekeeping (chore/ci/docs/test/build/
# refactor/style), merge commits, and any change reverted within the same range
# together with its revert. Trailing PR numbers — "(#207)", or "(#206) (#208)" on
# a cherry-pick — are stripped. Empty output when nothing is left, which leaves
# the appcast without a description. Only a staging rehearsal ever ships this;
# a release requires hand-written docs/release-notes/X.Y.Z.md (see below).
release_notes_from_subjects() {
  awk '
    function bare(s) {
      while (sub(/[[:space:]]*\(#[0-9]+\)[[:space:]]*$/, "", s)) {}
      return s
    }
    { subj[NR] = bare($0) }
    END {
      for (i = 1; i <= NR; i++) {
        if (subj[i] ~ /^Revert "/) {
          inner = subj[i]
          sub(/^Revert "/, "", inner)
          sub(/"$/, "", inner)
          reverted[bare(inner)] = 1
          is_revert[i] = 1
        }
      }
      for (i = 1; i <= NR; i++) {
        s = subj[i]
        if (s == "" || (i in is_revert) || (s in reverted)) continue
        if (tolower(s) ~ /^(chore|ci|docs|test|tests|build|refactor|style)(\(|:|!)/) continue
        if (s ~ /^Merge /) continue
        print "- " s
      }
    }'
}

# --- Release notes (docs/release-notes/X.Y.Z.md) ---
#
# What the update window shows, written by a person: a release build refuses to
# run without the file, the bump PR scaffolds it with a TODO that check.sh fails
# on, and `lint_release_notes` rejects the usual generated-copy tells. Commit
# subjects are only ever the raw material (and the automatic fallback for a
# staging rehearsal, which nobody but the tester sees).

# Path of the notes file for version $1.
release_notes_path() {
  printf '%s\n' "$REPO_ROOT/docs/release-notes/$1.md"
}

# Emit the scaffold release-bump.sh commits: the commits since v$1 as an HTML
# comment (context for the writer and the reviewer; stripped before shipping, so
# it can stay) and a TODO where the notes go. Subjects on stdin.
release_notes_template() {
  local subjects
  subjects="$(sed -e 's/--/- -/g' -e 's/^/     /')"
  cat <<EOF
<!-- Commits since v$1 (not shipped; context only):
${subjects:-     (none)}

Replace the TODO below with a short bullet list for users: what changed for
them, in plain words. At most 6 bullets of 100 characters each, each starting
with a capitalized verb. scripts/check-release-notes.sh enforces the rules. -->

TODO: write the release notes
EOF
}

# Content on stdin with each HTML comment blanked out but its newlines kept, so
# line N of the output is line N of the file — what the linter reports against.
release_notes_uncommented() {
  perl -0777 -pe 's/<!--.*?-->/"\n" x ($& =~ tr{\n}{})/gse'
}

# Content on stdin with HTML comments removed and surrounding blank lines
# trimmed: the text that actually ships in the appcast.
release_notes_body() {
  release_notes_uncommented | perl -0777 -pe 's/\A\s+//; s/\s+\z/\n/'
}

# Words and phrases that read as filler or generated copy. Matched
# case-insensitively as substrings; extend it when a new tic shows up. Nothing
# here may be part of a real Blurt feature name — "enhanced" is deliberately
# absent because "Enhanced transcripts" is a setting notes need to name.
RELEASE_NOTES_BANNED=(
  "seamless" "robust" "enhancement" "streamline" "leverag" "elevate"
  "delve" "a variety of" "various improvements" "various fixes" "under the hood"
  "we're excited" "we are excited" "excited to" "game-changer" "game changer"
  "cutting-edge" "effortless" "supercharge" "unlock" "empower" "revolutioniz"
  "bug fixes and improvements" "and more" "overall experience" "user experience"
)

# Allowed despite matching the code-identifier check (lowercase-then-uppercase).
RELEASE_NOTES_PROPER_NOUNS=(macOS iOS iCloud iPhone iPad visionOS watchOS AssemblyAI YouTube GitHub WhatsApp LinkedIn ChatGPT JetBrains PyCharm IntelliJ VoiceOver FaceTime AirPods)

# Lint release-notes content on stdin (the whole file; comments are stripped
# first). Prints one "line N: problem" per violation to stdout; returns 1 if any.
lint_release_notes() {
  local body line n=0 bullets=0 problems=0 lower phrase word stripped
  # Line-preserving, so "line N" is the file's line N. $(...) drops trailing
  # blank lines, which no reported line can be on.
  body="$(release_notes_uncommented)"
  _notes_problem() {
    printf 'line %s: %s\n' "$1" "$2"
    problems=$((problems + 1))
  }
  if [ -z "${body//[[:space:]]/}" ]; then
    printf 'line 0: no release notes — write at least one bullet\n'
    return 1
  fi
  while IFS= read -r line; do
    n=$((n + 1))
    [ -n "$line" ] || continue
    if [[ "$line" == *TODO* ]]; then
      _notes_problem "$n" "still has the TODO — write the notes"
      continue
    fi
    if [[ "$line" != "- "* ]]; then
      _notes_problem "$n" "every line must be a '- ' bullet (no headings or prose): $line"
      continue
    fi
    bullets=$((bullets + 1))
    line="${line#- }"
    [ "${#line}" -le 100 ] || _notes_problem "$n" "${#line} characters (max 100) — say less: $line"
    [[ "$line" =~ ^[A-Z] ]] || _notes_problem "$n" "start with a capitalized verb (\"Add…\", \"Fix…\"): $line"
    [[ ! "$line" =~ ^[Ww]e[[:space:]\'] ]] || _notes_problem "$n" "say what changed, not what \"we\" did: $line"
    lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
    for phrase in "${RELEASE_NOTES_BANNED[@]}"; do
      [[ "$lower" != *"$phrase"* ]] || _notes_problem "$n" "filler phrase \"$phrase\": $line"
    done
    [[ ! "$line" =~ \#[0-9]+ ]] || _notes_problem "$n" "PR/issue number — users can't use it: $line"
    [[ ! "$lower" =~ ^(chore|ci|docs|test|tests|build|refactor|style|feat|fix|perf)(\(.*\))?!?: ]] \
      || _notes_problem "$n" "commit-style prefix: $line"
    [[ "$line" != *'`'* ]] || _notes_problem "$n" "code formatting — describe it in words: $line"
    [[ ! "$line" =~ [A-Za-z0-9_]\.(swift|sh|ya?ml|json|plist|md|py|m|h)([^A-Za-z]|$) ]] \
      || _notes_problem "$n" "filename: $line"
    [[ ! "$line" =~ [A-Za-z0-9]_[A-Za-z0-9] ]] || _notes_problem "$n" "snake_case identifier: $line"
    stripped="$line"
    for word in "${RELEASE_NOTES_PROPER_NOUNS[@]}"; do stripped="${stripped//$word/}"; done
    [[ ! "$stripped" =~ [a-z][A-Z] ]] || _notes_problem "$n" "camelCase identifier (or add a proper noun to RELEASE_NOTES_PROPER_NOUNS): $line"
    if printf '%s' "$line" | perl -CS -ne 'exit(/[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{FE0F}]/ ? 0 : 1)'; then
      _notes_problem "$n" "emoji: $line"
    fi
  done <<<"$body"
  [ "$bullets" -le 6 ] || _notes_problem 0 "$bullets bullets (max 6) — keep what matters most to users"
  [ "$problems" -eq 0 ]
}

# Render a one-item Sparkle appcast to stdout. Arguments, in order: the short
# version (X.Y.Z), the build number (CFBundleVersion — what Sparkle actually
# compares), the enclosure URL, its EdDSA signature, its byte length, the
# release-notes page, the pubDate (RFC 822), and the changelog as Markdown
# (optional). One item is all the feed needs: Sparkle offers the newest
# applicable item, and the feed URL is always the current release's own copy.
#
# The changelog is what the update window shows. It goes inline as a Markdown
# <description> (Sparkle renders it natively, no web view) because the appcast
# is built, signed off, and checksummed before the release page exists — a
# `releaseNotesLink` to the GitHub page would load all of github.com's chrome
# into the window. `fullReleaseNotesLink` stays the "Version History" link.
render_appcast() {
  local short="$1" build="$2" url="$3" sig="$4" length="$5" notes="$6" date="$7" changelog="${8:-}"
  cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Blurt</title>
    <item>
      <title>Version $short</title>
      <pubDate>$date</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$short</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$notes</sparkle:fullReleaseNotesLink>
XML
  if [ -n "$changelog" ]; then
    # CDATA can hold anything but its own terminator; split any "]]>" across two
    # sections so a subject containing one can't end the block early.
    printf '      <description sparkle:format="markdown"><![CDATA[%s\n]]></description>\n' \
      "${changelog//]]>/]]]]><![CDATA[>}"
  fi
  cat <<XML
      <enclosure url="$url" type="application/octet-stream" sparkle:edSignature="$sig" length="$length"/>
    </item>
  </channel>
</rss>
XML
}
