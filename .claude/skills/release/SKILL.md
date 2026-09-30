---
name: release
description: Cut and publish a Blurt release (bump, release notes, build, sign, notarize, staple, DMG, Sparkle appcast, GitHub). Use when the user asks to ship/release a new version. User-invoked only — it has real side effects (notarization, git tags, GitHub release).
disable-model-invocation: true
---

# Releasing Blurt

Everything happens in GitHub Actions, not on this machine — so this works from a
web or chat session with no terminal, and without permission to dispatch a
workflow. **Confirm the target version with the user before starting** —
publishing is hard to undo.

## Preconditions (verify first)

- `main` is up to date and green; releases ship from `main`.
- The `release-build` environment has the signing + notary secrets and
  `SPARKLE_ED_PRIVATE_KEY`, and `release-publish` has required reviewers. See
  [`RELEASE.md`](../../../RELEASE.md) — that is the source of truth for custody.
  Without them the `release` workflow fails on its secrets-presence step.
- Check the highest existing `vX.Y.Z` tag, not just the version on `main`: an
  orphan tag from an abandoned release means the next patch number is already
  taken, and `release-bump.sh` refuses to reuse one.

## Steps

1. **Start `release-bump`.** You almost certainly can't dispatch a workflow (that
   needs `actions: write`), so push a marker branch instead — it needs only the
   push you already do:

   ```sh
   git push origin main:refs/heads/release/v0.1.37
   ```

   The branch name names the version, and it must carry nothing of its own: the
   workflow refuses a marker that isn't an ancestor of `main`. It then runs
   `scripts/release-bump.sh` on `macos-26` (marketing version + build number in
   `App/Blurt/project.yml`, regenerate the project, commit) and force-pushes the
   bump onto that same branch. Dispatching still works if you do have the
   permission, and only that path accepts an empty version (next patch).

2. **Get the release notes written.** The bump also commits
   `release-notes/X.Y.Z.md`: the commits since the last release in an HTML
   comment, and a `TODO` where the notes go. They are what Sparkle's update
   window shows every user, `check` fails while the `TODO` is there, and the
   release build refuses to run without them — there is no automatic fallback.
   Draft a few bullets from the commit list (at most 6, ≤100 characters, each
   starting with a verb, written for users — no PR numbers, filenames, or code
   names), run `scripts/check-release-notes.sh`, and **show the draft to the user
   and get their go-ahead before committing it** to the release branch. Their
   judgment is the point of the rule; see RELEASE.md → Release notes.
3. **Open the PR** for that branch and hand it to the user to merge. The workflow
   does not open it, on purpose: a PR created by `GITHUB_TOKEN` never triggers
   `check` and so can never merge. Opening it from here works — an agent's own
   credentials are not `GITHUB_TOKEN`.
4. **Merging it starts `release`** — no dispatch. `release.yml` triggers on a
   push to `main` touching `project.yml`; its `resolve` job confirms the version
   changed and isn't already tagged, then the `build` job does the whole Apple
   path (`xcodebuild` Release → sign nested code → notarize → staple → DMG →
   verify → EdDSA-sign the DMG → write `appcast.xml` with the notes) and uploads
   the artifacts. Dispatch `release` by hand only to re-run
   a failed build, to `republish`, or for a non-`main` dry run.
5. **Hand the ship gate to the user** — the `publish` job parks on the
   `release-publish` environment. Tell them to download the DMG from the run's
   artifacts, install it, and approve once it works. Nothing is rebuilt after
   approval, so what they test is what ships. `release-publish.sh` then tags,
   pushes, and publishes — and flipping the release to latest is what moves
   the Sparkle feed, so installed copies see it within a day.

**Never approve the `release-publish` deployment yourself**, even though the API
allows it. The gate exists so a human confirms the real artifact reached users in
working order; approving a build you started is not a gate. If the user wants
unattended releases, that is a deliberate change to the environment's reviewers,
not something to route around.

There is no local orchestrator script — the workflows are the only path.

## Guardrails / gotchas

- `release.yml`'s only push trigger is `main` + `project.yml` changed, narrowed
  further by `resolve` (version actually changed, no existing tag), and both jobs
  pin `github.sha` — so a release can only ever be the exact reviewed commit that
  carried the bump. Don't widen that trigger, and never add a tag trigger.
- `release-bump.yml`'s marker trigger is safe only because of its ancestor check
  (the branch carries nothing of its own) and because a `GITHUB_TOKEN` push
  doesn't re-fire the trigger. Don't drop either, and don't move that job to a
  PAT or app token without adding a loop guard.
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
- **Rehearse updater changes before shipping them.** Any change to Sparkle, the
  feed, signing, or the appcast should first pass the staging rehearsal
  (RELEASE.md → Rehearsing an update): `release` dispatched with `staging`
  checked builds for the `sparkle-staging` pre-release, and `publish` is skipped.
  A shipped build with a broken updater can't be fixed by an update.
- v0.1.57 and earlier have no updater, so the first Sparkle release (v0.1.58)
  reaches existing users only by manual download. Say so when announcing it.
- A `release` dispatch from a non-`main` ref is build-only (publish is skipped),
  but it only starts if `release-build`'s deployment-branch policy allows that
  ref — with the environment restricted to `main`, there is no branch dry run.

Read the script or workflow you're about to run before running it, surface what
it will do, and get a go-ahead before starting it. Pushing a marker branch is as
consequential as dispatching was — it starts the same pipeline.
