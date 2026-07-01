#!/usr/bin/env bash
# Blurt launch KPI snapshot from the GitHub API (read-only). See SKILL.md.
# Reports Blurt.dmg downloads, stars, and (if you have push access) traffic.
#
# $t and other jq variables in the --jq single-quoted programs are jq syntax,
# not shell expansions:
# shellcheck disable=SC2016
set -euo pipefail

REPO="${BLURT_REPO:-alexkroman/blurt}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not found — install it and run 'gh auth login'." >&2
  exit 1
fi

echo "== Blurt launch metrics — $REPO =="
echo

# Downloads: sum download_count over every asset named Blurt.dmg across releases.
echo "Blurt.dmg downloads (all releases):"
gh api "repos/$REPO/releases" --paginate \
  --jq '.[] | .tag_name as $t | .assets[] | select(.name=="Blurt.dmg")
        | "  \($t): \(.download_count)"' || echo "  (none yet)"
total="$(gh api "repos/$REPO/releases" --paginate \
  --jq '[.[].assets[] | select(.name=="Blurt.dmg") | .download_count] | add // 0')"
echo "  TOTAL: ${total}  (bands: ~500 baseline · ~1,500 good · 4,000+ great)"
echo

# Stars.
stars="$(gh api "repos/$REPO" --jq '.stargazers_count')"
echo "GitHub stars: ${stars}  (bands over launch: +100 baseline · +300 good · +800 great)"
echo

# Traffic (owner-only endpoints; fail soft if no push access).
# Uniques are the source of truth — raw view counts are inflated by bots and your
# own reloads, so we report unique visitors and rank referrers by uniques.
echo "Unique visitors (last 14 days):"
gh api "repos/$REPO/traffic/views" \
  --jq '"  \(.uniques) uniques"' \
  2>/dev/null || echo "  (needs push access to the repo)"
echo
echo "Top referrers by uniques (last 14 days):"
gh api "repos/$REPO/traffic/popular/referrers" \
  --jq 'sort_by(-.uniques) | .[] | "  \(.referrer): \(.uniques) uniques"' \
  2>/dev/null || echo "  (needs push access to the repo)"
