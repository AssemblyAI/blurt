---
name: release
description: Cut and publish a Blurt release (build, sign, notarize, staple, DMG, Datadog, GitHub). Use when the user asks to ship/release a new version. User-invoked only — it has real side effects (notarization, git tags, GitHub release, Datadog dSYM upload).
disable-model-invocation: true
---

# Releasing Blurt

The release pipeline lives in `scripts/`. Run it from the repo root. **Confirm
the target version with the user before publishing** — publishing is hard to undo.

## Preconditions (verify first)

- Clean working tree on an up-to-date `main` (releases ship from `main`).
- (Optional) `DATADOG_API_KEY` in the env for dSYM upload — needs Node/`npx`
  (datadog-ci). `DATADOG_SITE` defaults to `datadoghq.com` (US1). If unset, the
  build skips symbol upload with a warning rather than failing.
- Notary profile `blurt-notary` exists (`xcrun notarytool store-credentials`).
- Developer ID signing identity present in the keychain.

## Steps

1. **Bump the version** — `scripts/release-bump.sh` updates the marketing version
   and build number in `App/Blurt/project.yml`, regenerates the project, and
   opens a PR (versions land on `main` via PR — `main` is branch-protected).
2. **Build + sign + notarize** — `scripts/release-build.sh` does the whole Apple
   path: `xcodebuild` Release → sign nested code **including any embedded
   frameworks** (each must get `--options runtime --timestamp`, or notarization
   rejects it) → notarize → staple → DMG → verify. If `DATADOG_API_KEY` is set it
   also uploads the dSYM to Datadog (via `npx @datadog/datadog-ci`) so crashes
   symbolicate.
3. **Publish** — `scripts/release-publish.sh` creates the GitHub release and
   uploads `Blurt.dmg` (the README's download link points at
   `releases/latest/download/Blurt.dmg`).
4. **`scripts/release.sh`** orchestrates the above end-to-end; prefer it unless
   debugging a single stage.

## Guardrails / gotchas

- Run `scripts/check.sh` green before releasing — same gate as CI.
- Notarization rejects any nested mach-o/framework lacking a **secure
  timestamp**; the build re-signs frameworks for this reason — don't remove that.
- After a release, verify the DMG mounts, the app is stapled
  (`xcrun stapler validate`), and — if `DATADOG_API_KEY` was set — Datadog shows
  the uploaded dSYM.
- The post-build install step copies to `/Applications` (TCC needs a stable path);
  don't redirect it to DerivedData/`/tmp`.

Read the script you're about to run before running it, surface what it will do,
and get a go-ahead for the publish step.
