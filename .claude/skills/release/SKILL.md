---
name: release
description: Cut and publish a Blurt release (build, sign, notarize, staple, DMG, Datadog, GitHub). Use when the user asks to ship/release a new version. User-invoked only — it has real side effects (notarization, git tags, GitHub release, Datadog dSYM upload).
disable-model-invocation: true
---

# Releasing Blurt

Releases run in CI: the `release` workflow (`.github/workflows/release.yml`)
drives the `scripts/release-*.sh` pipeline on a `macos-26` runner. **Confirm
the target version with the user before kicking anything off** — publishing is
hard to undo.

## Normal path (CI)

1. **Open the bump PR** — dispatch the `release` workflow:
   `gh workflow run release` (add `-f version=X.Y.Z` for a minor/major; the
   default is the next patch after the latest published tag). The workflow
   opens a `release/vX.Y.Z` PR bumping `App/Blurt/project.yml`.
   (Running `scripts/release.sh [X.Y.Z]` locally opens the same PR.)
2. **Merge the PR** — merging is the "ship it" gate. The workflow re-fires on
   the push to `main` and builds, signs, notarizes, staples the DMG, uploads
   the dSYM to Datadog (when `DATADOG_API_KEY` is set), tags `vX.Y.Z`, and
   publishes the GitHub Release.
3. **Verify** — the release exists with `Blurt.dmg`, `Blurt-X.Y.Z.dmg`, and
   the dSYM zip attached; download the DMG, check it mounts and
   `xcrun stapler validate` passes; if `DATADOG_API_KEY` was set, Datadog
   shows the uploaded dSYM.

Bootstrap note: while **no `vX.Y.Z` tag exists yet**, the no-version default
targets the next patch — to publish the version already on `main`, dispatch
with `version` set to main's current version.

CI credentials are repo secrets (list + setup notes in the workflow header):
`APPLE_DEVELOPER_ID_P12` / `APPLE_DEVELOPER_ID_P12_PASSWORD`,
`NOTARY_APPLE_ID` / `NOTARY_PASSWORD`, optional `DATADOG_API_KEY`, optional
`RELEASE_TOKEN` (lets the bump PR trigger the required `check` workflow;
without it, close/reopen the PR to kick CI). For a manual approval gate before
publishing, add required reviewers to the `release` environment.

## Local fallback (debugging a stage, or CI down)

`scripts/release.sh [X.Y.Z]` orchestrates the same stages end-to-end from a
maintainer's Mac. Preconditions:

- Clean working tree on an up-to-date `main` (releases ship from `main`).
- (Optional) `DATADOG_API_KEY` in the env for dSYM upload — needs Node/`npx`
  (datadog-ci). `DATADOG_SITE` defaults to `datadoghq.com` (US1). If unset, the
  build skips symbol upload with a warning rather than failing.
- Notary profile `blurt-notary` exists (`xcrun notarytool store-credentials`).
- Developer ID signing identity present in the keychain.

Stages (prefer `release.sh` unless debugging a single one):

1. **Bump** — `scripts/release-bump.sh` updates the marketing version and build
   number in `App/Blurt/project.yml`, regenerates the project, and commits
   (versions land on `main` via PR — `main` is branch-protected).
2. **Build + sign + notarize** — `scripts/release-build.sh` does the whole
   Apple path: `xcodebuild` Release → sign nested code **including any embedded
   frameworks** (each must get `--options runtime --timestamp`, or notarization
   rejects it) → notarize → staple → DMG → verify → dSYM upload to Datadog.
3. **Install locally** — `scripts/release-install.sh` installs the notarized
   build to `/Applications` so you test the real artifact before publishing.
4. **Publish** — `scripts/release-publish.sh` tags, pushes, and creates the
   GitHub release with `Blurt.dmg` (the README's download link points at
   `releases/latest/download/Blurt.dmg`). `--yes` skips the confirmation (CI);
   `--republish` overwrites a broken release without bumping.

## Guardrails / gotchas

- `scripts/check.sh` must be green before releasing — the CI publish job skips
  it (`--skip-checks`) only because branch protection already ran it on the
  merge commit; locally, don't skip it.
- Notarization rejects any nested mach-o/framework lacking a **secure
  timestamp**; the build re-signs frameworks for this reason — don't remove that.
- After a release, verify the DMG mounts, the app is stapled
  (`xcrun stapler validate`), and — if `DATADOG_API_KEY` was set — Datadog shows
  the uploaded dSYM.
- The local post-build install step copies to `/Applications` (TCC needs a
  stable path); don't redirect it to DerivedData/`/tmp`.

Read the workflow/script you're about to run before running it, surface what it
will do, and get a go-ahead before the step that publishes (dispatching the
workflow is safe — it stops at the bump PR; merging that PR is the publish).
