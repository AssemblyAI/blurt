---
name: launch-metrics
description: Print a daily Blurt launch KPI snapshot — Blurt.dmg download count, GitHub stars, and repo traffic/referrers — and compare against the campaign's baseline/good/great bands. Use during launch week, or wrap with /loop for a recurring check.
---

# Blurt launch metrics

A $0 measurement backbone from the GitHub API (campaign §7). No analytics
vendor required — `gh` is the whole toolchain.

## What it reports

- **Blurt.dmg downloads** — the primary KPI. Summed `download_count` across
  releases' `Blurt.dmg` assets. Bands (4-week, campaign §1): baseline ~500,
  good ~1,500, great 4,000+.
- **GitHub stars** — bands: baseline +100, good +300, great +800.
- **Unique visitors & referrers** — uniques are the source of truth (raw view
  counts are inflated by bots and your own reloads, so the script reports unique
  visitors and ranks referrers by uniques). Needs push access; the
  `repos/.../traffic/*` endpoints are owner-only. Watch for awesome-list and
  dev-site referrers as the evergreen layer kicks in (§7).

## Run it

```bash
.claude/skills/launch-metrics/metrics.sh
```

Requires `gh auth status` to be logged in. The script is read-only.

## Recurring during launch week

Wrap with the built-in loop for the §7 daily cadence:

```text
/loop 1d /launch-metrics
```

Then drop to a weekly check for the rest of the month. Note the script gives a
point-in-time download total; track the day-over-day delta yourself (or paste the
prior day's number) to see the rate, which is what the bands are really about.
