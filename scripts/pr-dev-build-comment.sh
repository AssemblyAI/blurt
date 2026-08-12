#!/usr/bin/env bash
# Render — and optionally post — the per-PR dev-build comment.
#
# One definition, three callers: check.yml writes it to the run's step summary
# and posts it for same-repo PRs, and pr-dev-build.yml posts it for fork PRs
# (see those files for why the fork case needs a separate workflow). The install
# instructions have to stay identical across all three, so they live here rather
# than in three heredocs that drift.
#
# Usage:
#   pr-dev-build-comment.sh --render     # markdown to stdout
#   pr-dev-build-comment.sh --post       # upsert it as a PR comment (needs gh)
#
# Inputs arrive as environment variables:
#   REPO           owner/repo
#   ARTIFACT_NAME  e.g. blurt-dev-build-pr-109
#   ARTIFACT_URL   browser URL of the uploaded artifact
#   HEAD_SHA       full sha of the PR head
#   PR             pull request number (--post only)
#   GH_TOKEN       token with pull-requests: write (--post only)

set -euo pipefail

# The marker is how a later run finds this comment and edits it in place, so a
# long-running PR carries one link that stays current rather than a stack of
# stale ones. Both callers use it, so both converge on the same comment.
#
# The body says "built from <sha>" rather than naming it as the PR head: a
# docs-only push skips the dev-build job (and this comment with it), so the
# newest build can legitimately lag the branch tip. Stating what the build IS
# stays true in that case; claiming it is the current head would not.
readonly MARKER="<!-- blurt-dev-build -->"

usage() {
  echo "usage: $(basename "$0") --render|--post" >&2
  exit 2
}

require_env() {
  local name
  for name in "$@"; do
    [ -n "${!name:-}" ] || {
      echo "error: $name is required" >&2
      exit 1
    }
  done
}

render() {
  local short_sha="${HEAD_SHA:0:7}"
  cat <<EOF
$MARKER
### Dev build

[**Download Blurt.app**]($ARTIFACT_URL) — built from \`$short_sha\`, \`Debug-Local\`,
ad-hoc signed. Expires in 14 days.

<details>
<summary>Installing it</summary>

\`\`\`sh
cd ~/Downloads
unzip -o $ARTIFACT_NAME.zip   # GitHub wraps every artifact in a zip
unzip -o Blurt-dev-$short_sha.zip
find Blurt.app -exec xattr -c {} +   # clear quarantine: xattr lost -r in macOS 12.3
rm -rf /Applications/Blurt.app && cp -R Blurt.app /Applications/
open -a Blurt
\`\`\`

It is **ad-hoc signed and not notarized**: Gatekeeper refuses to open it until
the quarantine flag is cleared, and macOS treats it as a different app from a
released Blurt, so you have to re-grant Microphone, Accessibility, and Input
Monitoring. Reinstall the [release DMG](https://github.com/$REPO/releases/latest)
when you are done reviewing.

Expect that re-grant **once per dev build**, including a second build of this
same PR. TCC pins an Accessibility grant to the signature that took it, and an
ad-hoc signature is just a hash of the binary, so every build is a new app as far
as \`tccd\` is concerned. Blurt clears the orphaned grant at launch, which is what
keeps the Accessibility step from getting stuck on a Blurt row that is switched on
and still denied. If you are coming from a build old enough to predate that,
clear the grant yourself once:

\`\`\`sh
tccutil reset Accessibility dev.alex.blurt
\`\`\`

</details>
EOF
}

post() {
  local body existing
  body="$(mktemp)"
  render >"$body"

  # jq's `first` over each page rather than `| head -1`: closing the pipe early
  # would SIGPIPE gh, and under `set -o pipefail` that is a failure.
  existing="$(gh api "repos/$REPO/issues/$PR/comments" --paginate \
    --jq "[.[] | select(.body | contains(\"$MARKER\")) | .id] | first // empty")"
  if [ -n "$existing" ]; then
    gh api -X PATCH "repos/$REPO/issues/comments/$existing" -F "body=@$body" >/dev/null
    echo "updated comment $existing on PR #$PR"
  else
    gh api -X POST "repos/$REPO/issues/$PR/comments" -F "body=@$body" >/dev/null
    echo "commented on PR #$PR"
  fi
  rm -f "$body"
}

[ $# -eq 1 ] || usage
case "$1" in
  --render)
    require_env REPO ARTIFACT_NAME ARTIFACT_URL HEAD_SHA
    render
    ;;
  --post)
    require_env REPO ARTIFACT_NAME ARTIFACT_URL HEAD_SHA PR
    post
    ;;
  *) usage ;;
esac
