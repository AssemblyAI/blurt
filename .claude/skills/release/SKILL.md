---
name: release
description: Cut and publish a Blurt release (build, sign, notarize, staple, DMG, GitHub). Use when the user asks to ship/release a new version. User-invoked only — it has real side effects (notarization, git tags, GitHub release).
disable-model-invocation: true
---

# Releasing Blurt

`scripts/release.sh` is the entry point; the build, signing, notarization, and
publish all happen in the `release` GitHub Actions workflow
(`.github/workflows/release.yml`), not on this machine. **Confirm the target
version with the user before dispatching** — publishing is hard to undo.

## Preconditions (verify first)

- `main` is up to date and green; releases ship from `main`.
- The commit you are releasing has been **tried as an app**, not just reviewed:
  every merge to `main` uploads `blurt-dev-build-main-<short-sha>` from the
  `check` workflow's `dev-build` job (Actions → check → that commit's run, link
  in the run summary, kept 30 days). Say which build was installed, or say it
  wasn't.
- `gh` is authenticated and can dispatch workflows on the repo.
- The `release-build` environment has the signing + notary secrets, and
  `release-publish` has required reviewers. See
  [`RELEASE.md`](../../../RELEASE.md) — that is the source of truth for custody.

## Steps

1. **Bump the version** — `scripts/release.sh [X.Y.Z]` run 1 calls
   `release-bump.sh` (marketing version + build number in
   `App/Blurt/project.yml`, regenerate the project) and opens a PR. Versions land
   on `main` via PR — `main` is branch-protected.
2. **Merge the PR.**
3. **Dispatch** — re-run the same `scripts/release.sh [X.Y.Z]`. It dispatches the
   workflow against `origin/main` and follows the run. The `build` job does the
   whole Apple path (`xcodebuild` Release → sign nested code → notarize → staple
   → DMG → verify) and uploads the artifacts.
4. **Approve the ship gate** — the `publish` job parks on the `release-publish`
   environment. Download the DMG from the run's artifacts, install it, confirm it
   works, then approve. Nothing is rebuilt after approval, so what was tested is
   what ships. `release-publish.sh` then tags, pushes, and publishes.

Dispatching from a branch other than `main` runs build-only (the publish job is
skipped) — that's the way to dry-run a change to the signing path.

## Guardrails / gotchas

- The workflow is dispatch-only and both jobs pin `github.sha`, so a release can
  only ever be the exact reviewed commit. Don't add a push/tag trigger.
- Notarization rejects any nested mach-o/framework lacking a **secure
  timestamp**; the build re-signs frameworks for this reason — don't remove that.
- The signer-pin (`verify_signer`) checks the produced artifacts against a
  hardcoded leaf-cert SHA-256 and Team ID. If the cert rotates, both pins in
  `release-build.sh` must be updated — see RELEASE.md.
- A bad release rolls **forward** (bump a patch). `republish` is only for a
  corrupted upload caught before announcing, never a code bug.
- Running the scripts directly on a Mac still works for debugging a single stage
  (`release-build.sh --skip-checks`, `release-install.sh`), and uses the local
  locked signing keychain rather than the CI secrets.

Read the script or workflow you're about to run before running it, surface what
it will do, and get a go-ahead before dispatching.
