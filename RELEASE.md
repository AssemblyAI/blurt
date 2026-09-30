# Release runbook

Blurt is built, signed, notarized, and published by GitHub Actions, not from a
maintainer's Mac. Every step is a workflow run or a click in the GitHub UI, so a
release can be driven from a browser, a phone, or a chat session with no terminal
anywhere in the loop. This file covers the security-critical custody and policy
decisions that aren't obvious from the scripts and the workflows.

## Shape of a release

| Stage                                                 | Where                                                             | Gate                                                                                         |
| ----------------------------------------------------- | ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Bump `CFBundleShortVersionString` + `CFBundleVersion` | `release-bump` workflow on `macos-26` (`scripts/release-bump.sh`) | Lands on `main` via PR: normal review + the `check` workflow — merging it starts the release |
| Build → sign → notarize → staple → DMG → appcast      | `release` workflow, `build` job (`scripts/release-build.sh`)      | Signer-pin, Gatekeeper assessment, mount-and-verify, EdDSA verify (all in-script)            |
| Tag, push, publish the GitHub Release + appcast       | `release` workflow, `publish` job (`scripts/release-publish.sh`)  | **Required reviewer on the `release-publish` environment**                                   |

Start to finish:

1. **Start `release-bump`**, either by pushing a marker branch `release/vX.Y.Z`
   at `main` or by dispatching the workflow. It bumps `project.yml`, regenerates
   the project, and leaves the bump commit on `release/vX.Y.Z`. It deliberately
   does **not** open the PR — events created by `GITHUB_TOKEN` don't trigger
   workflows, so a PR opened from inside Actions would never get a `check` run
   and could never merge. The job summary links a one-click compare page.
2. **Open that PR and merge it.** Opened from outside Actions — by a person or
   by an agent with its own credentials — `check` runs normally. **Merging it
   starts `release`**; there is nothing to dispatch.
3. **Approve the `release-publish` deployment** once you've tested the DMG.

So a release is two clicks on the maintainer's side: merge the bump PR, approve
the ship gate. Everything between them is the workflow's, and step 1 needs no
Actions permission — which is what lets an agent start the whole thing.

### Starting a bump without a dispatch

Dispatching a workflow needs the Actions UI or an API token with `actions:
write`. Pushing a branch doesn't, and a chat or web session generally has the
latter and not the former. So `release-bump` also triggers on a push of
`release/v[0-9]*`:

```sh
git push origin main:refs/heads/release/v0.1.37   # names the version; carries nothing
```

The branch name **is** the request — it names the version, and there is no
`default_target` guessing on this path. The workflow then checks out `main`,
verifies the marker is an **ancestor of `main`** (so it carries no commits of
its own), bumps on top of `main`'s tip, and force-pushes the result onto the
same branch, with the lease pinned to the exact sha it vetted.

That ancestor check is the security-relevant one. Without it, pushing a branch
would be a way to get a bot-authored commit sitting on top of arbitrary content,
and the PR that followed would quietly be about more than a version bump. With
it, the marker is a signal and the only commit that ends up on the branch is the
bump.

This path leans on the `GITHUB_TOKEN` rule in the opposite direction from
everywhere else here: the bump commit the job force-pushes does **not** re-fire
the push trigger that started it, which is what keeps it from looping. Don't
move this job to a PAT or an app token without adding a loop guard.

Re-pushing a marker that already carries the bump commit fails the ancestor
check with a message saying so — the job already ran; open the PR.

### What starts a release

A release is a deliberate act against one reviewed commit — never a side effect
of an arbitrary push, and never a tag trigger. Two things qualify:

- **The version-bump PR merging into `main`.** The push carries a changed
  `CFBundleShortVersionString`, which is what `release.yml`'s path filter and its
  `resolve` job look for. That merge is the deliberate act: the commit is
  reviewed, it passed `check`, and it is one specific sha.
- **A manual dispatch**, for re-running a release whose build failed, for
  `republish`, and for the non-`main` build-only dry run.

`resolve` runs first, on Linux, before any macOS minutes or the signing key are
spent. On a push it releases only when the version actually changed (it diffs
`project.yml` against the push's previous commit) **and** no `vX.Y.Z` tag exists
yet; otherwise the run ends with the build and publish jobs skipped. So a
project.yml edit that adds a source file doesn't build a release, and a re-merge
after a shipped version doesn't republish one. Both jobs still check out
`github.sha`, so the tag cannot land on a commit other than the one built.

The merged-bump path never passes `skip_checks`, `skip_smoke`, or `republish` —
those are dispatch-only, because nobody is standing there to judge whether
skipping was safe.

One `GITHUB_TOKEN` caveat, the mirror of the one that keeps `release-bump` from
opening the PR: a merge performed **by** Actions with `GITHUB_TOKEN` doesn't
raise a `push` event, so it wouldn't start `release` either. A person clicking
Merge, GitHub's auto-merge, or an agent using its own credentials all work.

Leave the version input empty and `release-bump` takes the next patch itself,
using the same `default_target` / `decide_run` rules the release scripts have
always used (`scripts/release-lib.sh`, unit-tested by `release.test.sh`). It
refuses rather than guesses when the state is ambiguous: if `main` already
carries an unreleased bump it tells you to dispatch `release` instead, and if the
next patch number is already taken by a tag it stops and asks for an explicit
version rather than silently renumbering your release.

### Dry-running the signing path

A dispatch of `release` from any ref other than `main` runs the `build` job and
**stops** — the `publish` job is skipped — so the signing and notarization path
can be exercised without shipping anything.

Whether that is actually available depends on the `release-build` environment's
deployment-branch policy, because the `build` job declares that environment:

- **`main` only** — the tightest setting, and the branch dry run is _not_
  available: a dispatch from any other ref is blocked before the job starts.
- **`main` plus a pattern like `release-dry-run*`** — rehearsals work from a
  branch matching that pattern, and the signing key stays unreachable from
  every other branch.

**Recommended: `main` only.** The asymmetry decides it. Skipping a rehearsal
costs you a failed build and a re-dispatch — the publish job still gates on
approval, so a botched signing change cannot reach users. Standing access from a
branch pattern costs you a permanent widening of who can reach the one credential
whose compromise means someone signs malware as you and Gatekeeper accepts it:
anyone who can push a branch could dispatch a workflow on it that prints the key.

If you ever do need a rehearsal, add the pattern, run it, and remove it. That is
a deliberate and auditable act, which is exactly what touching this key should
be — unlike a standing grant nobody revisits.

### The ship gate

The old flow installed the notarized build to `/Applications` and asked the
operator "continue?" — a human tested the real artifact before it was published.
The workflow keeps that gate as a **required reviewer on the `release-publish`
environment**: the publish job parks until someone approves it. Approve only
after downloading the DMG from the build job's run artifacts and installing it.
Nothing is rebuilt after approval, so what you test is byte-for-byte what ships.

## Required repository configuration

Two environments (Settings → Environments). They are what scope the secrets, so
neither is optional.

**`release-build`** — holds the signing and notary secrets. Set its deployment
branches to `main` (optionally plus a `release-dry-run*` pattern — see
[Dry-running the signing path](#dry-running-the-signing-path)) so a fork or a
stray branch can never reach the Developer ID key.

| Secret                   | What                                                                                                    |
| ------------------------ | ------------------------------------------------------------------------------------------------------- |
| `SIGNING_P12_BASE64`     | Developer ID Application cert **and** private key, exported as `.p12`, base64-encoded                   |
| `SIGNING_P12_PASSWORD`   | The export password for that `.p12`                                                                     |
| `NOTARY_KEY_P8_BASE64`   | App Store Connect API key (`.p8`), base64-encoded — the preferred notary credential                     |
| `NOTARY_KEY_ID`          | That key's Key ID                                                                                       |
| `NOTARY_ISSUER_ID`       | That key's Issuer ID                                                                                    |
| `NOTARY_APPLE_ID`        | _Fallback only_ — Apple ID for notarization, if no API key is available                                 |
| `NOTARY_PASSWORD`        | _Fallback only_ — app-specific password for that Apple ID                                               |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle's EdDSA private key, as `generate_keys -x` exports it — see [Sparkle updates](#sparkle-updates) |

Prefer the API key. It is revocable on its own (an app-specific password is tied
to the Apple ID that owns it), it needs no keychain, and it never appears in a
process list — `notarytool --password` does.

**`release-publish`** — holds no secrets. Its only job is the approval gate, so
configure **required reviewers** on it. Without that it is just a rubber stamp
and the release publishes unattended.

Producing the two base64 values:

```sh
# Signing identity: export from Keychain Access (or `security export`) as .p12,
# then encode. Keep the .p12 itself offline; never commit it, never sync it.
base64 -i Blurt-DeveloperID.p12 | pbcopy      # -> SIGNING_P12_BASE64

# Notary API key: download the .p8 once from App Store Connect (Users and
# Access -> Integrations -> Keys). Apple will not let you download it twice.
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy      # -> NOTARY_KEY_P8_BASE64
```

## Signing key custody

The Developer ID Application key (`602F699488189767137DF15633B967B1371ACD86`,
team `B2VQF7Q2QY`) is the root of trust: Gatekeeper accepts anything signed with
it, so every published DMG must carry this signature. Protect it accordingly:

- The canonical copy is the `SIGNING_P12_BASE64` secret on the `release-build`
  environment. Keep the encrypted `.p12` backup **offline** — not on disk on a
  work machine, not in cloud sync.
- `release-build.sh` imports it into an **ephemeral keychain** created in a temp
  directory for that run and deleted on exit (success, failure, or `die` alike),
  with a random per-run password that never leaves the process. The key is never
  written to a persistent keychain on the runner, and the runner itself is
  destroyed after the job.
- The build then **pins the signer**: `verify_signer` re-derives the leaf
  certificate's SHA-256 fingerprint and the Team ID from the produced artifacts
  and refuses to continue unless both match the constants in
  `release-build.sh`. A build signed with any other (even otherwise-valid)
  Developer ID fails closed rather than shipping.
- **Local signing still works** for debugging a single stage on a Mac. With no
  `BLURT_SIGNING_P12_BASE64` in the environment, `release-build.sh` falls back to
  a dedicated keychain that stays **locked at rest**
  (`~/Library/Keychains/blurt-signing.keychain-db`), with a tight partition-list
  ACL (only `codesign` / `productsign` may use it) and a 15-minute auto-lock. It
  unlocks that keychain for the duration of the build and re-locks it on exit.
  The unlock password is resolved from, in order:
  `BLURT_SIGNING_KEYCHAIN_PASSWORD`, then `BLURT_SIGNING_KEYCHAIN_OP` (an
  `op://…` 1Password reference the script runs `op read` on — Touch ID fires),
  then an interactive prompt. It does **not** read the password from the login
  keychain, so the unlock secret never sits in login.

  ```sh
  export OP_ACCOUNT=assemblyai.1password.com
  export BLURT_SIGNING_KEYCHAIN_OP='op://Employee/Blurt signing keychain/password'
  scripts/release-build.sh --skip-checks
  ```

  Override the keychain path with `BLURT_SIGNING_KEYCHAIN` if it lives elsewhere.
  On that path the notary credential comes from the `blurt-notary` keychain
  profile, pinned to the signing keychain so a duplicate profile elsewhere on the
  search list can't shadow it.

- **Everyday dev builds never touch this key.** The `Debug` / `Debug-Local`
  configs sign with the **Apple Development** cert (login keychain, same team
  `B2VQF7Q2QY`), so `scripts/dev-build.sh` and Xcode builds work with the release
  keychain locked. Only `release-build.sh` uses the Developer ID key.

## Rotating the signing certificate

If the key is compromised (or the cert expires):

1. Revoke the Developer ID Application certificate in the Apple Developer portal.
2. Issue a new Developer ID Application certificate **on the same team**
   (`B2VQF7Q2QY`).
3. Update `IDENTITY` (the SHA-1 identity hash, from
   `security find-identity -v -p codesigning`) **and** `IDENTITY_SHA256` (the
   leaf cert's SHA-256 fingerprint, from
   `openssl x509 -noout -fingerprint -sha256 -in <cert.pem>`) in
   `scripts/release-build.sh`. Both are pinned; a stale `IDENTITY_SHA256` fails
   the build at `verify_signer` rather than shipping the wrong signer.
4. Re-export the new cert + key as a `.p12` and replace `SIGNING_P12_BASE64` and
   `SIGNING_P12_PASSWORD` on the `release-build` environment.
5. Cut a fresh notarized release.

Rotating to a new cert **within the same team** (`B2VQF7Q2QY`) is seamless for
users — Gatekeeper accepts any valid Developer ID from any team, and updates are
a manual DMG download (see [Updates in AGENTS.md](./AGENTS.md#updates)), so there
is no signing-requirement pin to break. A **team change** (new Team ID) is still
worth avoiding on principle and announcing, but it no longer strands existing
users the way the former in-app updater's team-pinned requirement did.

## Rotating the notary credential

**API key (CI):** revoke the key in App Store Connect (Users and Access →
Integrations → Keys), generate a new one, download the `.p8` once, and replace
`NOTARY_KEY_P8_BASE64` / `NOTARY_KEY_ID` / `NOTARY_ISSUER_ID`.

**App-specific password (the CI fallback, and the local keychain profile):**
revoke the old password at appleid.apple.com and mint a new one. For CI, replace
`NOTARY_PASSWORD`. For a local `blurt-notary` profile, re-run
`xcrun notarytool store-credentials blurt-notary --keychain
~/Library/Keychains/blurt-signing.keychain-db --apple-id <you> --team-id
B2VQF7Q2QY --password <new-app-specific-password>`. The profile is submit-only;
it cannot sign.

## Sparkle updates

Installed copies update themselves with [Sparkle](https://sparkle-project.org).
Each release carries an `appcast.xml` asset; every installed copy polls
`https://github.com/AssemblyAI/blurt/releases/latest/download/appcast.xml`
(`SUFeedURL`, from the `BLURT_SPARKLE_FEED_URL` build setting in `project.yml`),
so the feed moves to a release at the moment
`release-publish.sh` flips it live and repoints `/latest` — never before its
assets are verified. The appcast's one item names the versioned
`Blurt-X.Y.Z.dmg` on that release, with the DMG's EdDSA signature and length.

`release-build.sh` produces it: after the DMG is notarized and stapled, Sparkle's
`sign_update` (from the SPM artifact in DerivedData) signs it, and
`scripts/verify-sparkle-signature.swift` checks that signature against the
`SUPublicEDKey` read out of the **built app** — the key every installed copy
will check — before the appcast is written. A private key that doesn't match
fails the build, not users' updates. The build reads `SUFeedURL` back out of
the built app the same way, and refuses to start while `SPARKLE_PUBLIC_ED_KEY`
is still the placeholder.

Sparkle compares `CFBundleVersion` (`sparkle:version`), not the marketing
version, so the build number must rise with every release — `release-bump.sh`
already increments it on each bump.

### Release notes

The update window shows the appcast item's `<description>`, which
`release-build.sh` writes as Markdown (Sparkle renders it natively) from
**`docs/release-notes/X.Y.Z.md`** — written by a person, every release:

- **The bump PR scaffolds it.** `release-bump.sh` commits the file with the
  commits since the previous release in an HTML comment (context for the writer
  and the reviewer; comments never ship) and a `TODO` where the notes go.
  `check` fails while the `TODO` is there, so the bump PR can't merge until the
  notes are written — and approving that PR is the editorial review.
- **A release build refuses to run without it.** There is no automatic
  fallback for a release; commit subjects are written for reviewers, not users.
  (A `--staging` rehearsal alone falls back to filtered commit subjects, since
  only the tester sees them.)
- **`scripts/check-release-notes.sh` lints it** (via `check.sh`, and again in the
  build), using `lint_release_notes` in `release-lib.sh`:
  - bullets only, at most **6**, each at most **100** characters;
  - each starts with a capital letter — lead with the verb ("Add…", "Fix…",
    "Paste now works in…") — and none with "We";
  - no filler: _seamless, robust, enhanced, streamlined, leverage, elevate,
    delve, a variety of, various improvements, under the hood, we're excited_,
    and more (`RELEASE_NOTES_BANNED` — add to it when a new tic shows up);
  - no emoji;
  - no developer leakage: PR numbers, `chore:`/`fix:` prefixes, backticks,
    filenames, `snake_case` or `camelCase` identifiers (real product names like
    macOS or YouTube are allow-listed in `RELEASE_NOTES_PROPER_NOUNS`).

The lint only catches the obvious. Write for someone who has never seen the
repo: what changed for them, in plain words, most important first. Then read
it where users will — the rehearsal below shows the real window.

Because the rehearsal fallback and the bump scaffold both measure from tags, the
build job checks out with full history; a shallow checkout fails fast.

### Rehearsing an update

A shipped build whose updater is broken can't be fixed by an update, so every
user it reaches has to download again by hand. Before the first Sparkle release
— and before any change to the updater, the feed, the signing, or the appcast —
prove that an installed build updates itself, using the real pipeline:
Developer ID, notarization, the CI secret, and GitHub's download redirects.

The one difference is the feed. `release-build.sh --staging` builds an app that
polls the **`sparkle-staging`** prerelease instead of `/latest`, with an appcast
whose DMG lives there too. That prerelease is never marked latest, so
`/releases/latest/download/` — every shipped copy's feed — can't resolve to it,
and `release-publish.sh` refuses to publish a staging build.

1. Push the rehearsal to a branch matching `release-dry-run*`, and temporarily
   add that pattern to the `release-build` environment's deployment branches
   (see [Dry-running the signing path](#dry-running-the-signing-path) — with the
   recommended `main`-only policy, a dispatch from any other branch is blocked
   before it builds). Dispatch **release** from that branch with **staging**
   checked (and the version the branch carries). The build signs and notarizes as
   usual; the `stage` job then uploads the DMG and appcast to `sparkle-staging`,
   creating it the first time. This is **rc1**.
2. Download rc1's DMG from the run's artifacts (not from the prerelease, which
   the next step overwrites) and install it into `/Applications`, the way a user
   would. Grant its permissions and dictate once.
3. On the same branch, raise `CFBundleVersion` in `project.yml` by one (Sparkle
   compares the build number), add or edit
   `docs/release-notes/X.Y.Z.md` to see the real notes (without it, a staging
   build shows filtered commit subjects), push, and dispatch again with
   **staging** checked. This is **rc2**, and it replaces rc1 on the feed.
4. In rc1, choose **Check for Updates…**.

Check, in order:

- The update window names rc2 and shows the changelog — and the notes read
  well there: short enough to take in at a glance, nothing a user would have to
  look up. Adjust `docs/release-notes/X.Y.Z.md` until they do.
- It downloads, installs, and relaunches as rc2 (Settings → Updates shows the
  version).
- **Accessibility survives**: dictate into another app right after the
  relaunch. If the paste fails, the update broke the grant — don't ship.
- **Install on quit**: stage an rc3, turn on "Download and install updates
  automatically", quit, relaunch, and confirm it is rc3.
- An update found mid-dictation doesn't interrupt the recording.
- Launched from `~/Downloads` instead of `/Applications` (App Translocation),
  Sparkle either updates or says why — it doesn't fail silently.
- From a standard (non-admin) account, it asks for an administrator password
  rather than failing.

Remove the branch pattern from `release-build` when you're done. A rehearsed
copy keeps polling `sparkle-staging`. Delete it afterwards and
install the real release, or it will only ever see staged builds.

For fast iteration on the update window's look alone, a local loop is quicker:
two locally signed builds with the shipping bundle id, a hand-written appcast,
and `python3 -m http.server`. It skips everything the rehearsal exists to
prove, so it is no substitute.

### One-time setup: the key pair

The EdDSA key pair is the updater's root of trust, separate from the Developer
ID key: an installed copy only installs an archive signed by the private half of
the public key it shipped with. On the maintainer's Mac, with Sparkle's tools
(in the Sparkle release tarball, or `…/SourcePackages/artifacts/sparkle/Sparkle/bin/`
after any build):

```sh
./bin/generate_keys                  # creates the pair in the login keychain; prints the public key
./bin/generate_keys -x sparkle.key   # exports the private key for the CI secret
```

1. Put the printed public key in `App/Blurt/project.yml` as
   `SPARKLE_PUBLIC_ED_KEY`, replacing the placeholder, and land it through the
   normal PR flow.
2. Paste the contents of `sparkle.key` into the `SPARKLE_ED_PRIVATE_KEY` secret
   on the `release-build` environment, then delete the file.
3. Back up the private key outside the keychain and never commit it. The
   current backup is a 1Password document, "Blurt Sparkle EdDSA private key",
   in the maintainer's private vault — not a shared one, since anyone holding
   the key can sign an update installed copies accept (together with the
   Developer ID key; see below). An offline copy beside the Developer ID `.p12`
   is a sensible second.

### Key custody and rotation

**Losing the private key strands every installed copy** — nothing else can sign
an update they will accept, so they'd have to download a new DMG by hand. Keep
the offline backup.

A **leaked** private key lets whoever holds it sign an update installed copies
will accept — though Sparkle also requires the update to carry the same
Developer ID signature as the running app, so the attacker would need both keys.
To rotate: generate a new pair, ship one bridge release that is signed with the
**old** private key but carries the **new** `SPARKLE_PUBLIC_ED_KEY` (run that one
build with `BLURT_SPARKLE_VERIFY_PUBLIC_KEY` set to the old public key, since the
build otherwise verifies against the key the app carries), then switch the
secret to the new private key for every release after it.

## A bad release: roll forward, never roll back

Blurt does **not** yank published releases. Sparkle only ever offers users a
strictly higher `CFBundleVersion` than the one they're running, so the fix for
any bad build is to **ship a new patch**: dispatch `release-bump`, merge,
dispatch `release`.

The one exception is a fault caught **before announcing**, while the same version
is still safe to overwrite (e.g. a corrupted upload flagged by the post-publish
verification step): dispatch the `release` workflow again with **`republish`
checked**, which deletes and recreates the tag and its release with fresh
artifacts. A code bug is never a republish — bump a patch.

```sh
gh workflow run release.yml --ref main -f version=X.Y.Z -f republish=true
```
