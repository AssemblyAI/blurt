---
name: release
description: Cut and publish a Blurt release (build, sign, notarize, staple, DMG, GitHub). Use when the user asks to ship/release a new version. User-invoked only — it has real side effects (notarization, git tags, GitHub release).
disable-model-invocation: true
---

# Releasing Blurt

Everything happens in GitHub Actions, not on this machine — so this works from a
web or chat session with no terminal. **Confirm the target version with the user
before dispatching** — publishing is hard to undo.

## Preconditions (verify first)

- `main` is up to date and green; releases ship from `main`.
- The `release-build` environment has the signing + notary secrets, and
  `release-publish` has required reviewers. See
  [`RELEASE.md`](../../../RELEASE.md) — that is the source of truth for custody.
  Without them the `release` workflow fails on its secrets-presence step.
- Check the highest existing `vX.Y.Z` tag, not just the version on `main`: an
  orphan tag from an abandoned release means the next patch number is already
  taken, and `release-bump.sh` refuses to reuse one.

## Steps

1. **Dispatch `release-bump`** with the target version. It runs
   `scripts/release-bump.sh` on `macos-26` (marketing version + build number in
   `App/Blurt/project.yml`, regenerate the project, commit) and pushes
   `release/vX.Y.Z`.
2. **Open the PR** for that branch and merge it once green. The workflow does not
   open it, on purpose: a PR created by `GITHUB_TOKEN` never triggers `check` and
   so can never merge. Opening it from here works — an agent's own credentials
   are not `GITHUB_TOKEN`.
3. **Dispatch `release`** with the same version. The `build` job does the whole
   Apple path (`xcodebuild` Release → sign nested code → notarize → staple → DMG
   → verify) and uploads the artifacts.
4. **Hand the ship gate to the user** — the `publish` job parks on the
   `release-publish` environment. Tell them to download the DMG from the run's
   artifacts, install it, and approve once it works. Nothing is rebuilt after
   approval, so what they test is what ships. `release-publish.sh` then tags,
   pushes, and publishes.

**Never approve the `release-publish` deployment yourself**, even though the API
allows it. The gate exists so a human confirms the real artifact reached users in
working order; approving a build you dispatched is not a gate. If the user wants
unattended releases, that is a deliberate change to the environment's reviewers,
not something to route around.

`scripts/release.sh` does steps 1–3 from a Mac terminal instead. Both work; the
workflows are canonical.

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
- A `release` dispatch from a non-`main` ref is build-only (publish is skipped),
  but it only starts if `release-build`'s deployment-branch policy allows that
  ref — with the environment restricted to `main`, there is no branch dry run.

Read the script or workflow you're about to run before running it, surface what
it will do, and get a go-ahead before dispatching.
