# Release runbook

Blurt is built, signed, notarized, and published by the **`release` GitHub
Actions workflow** (`.github/workflows/release.yml`), not from a maintainer's
Mac. `scripts/release.sh` drives the whole thing: run 1 opens the version-bump
PR, run 2 dispatches the workflow and follows it. This file covers the
security-critical custody and policy decisions that aren't obvious from the
scripts and the workflow.

## Shape of a release

| Stage                                                 | Where                                                  | Gate                                                                |
| ----------------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------- |
| Bump `CFBundleShortVersionString` + `CFBundleVersion` | Local (`scripts/release-bump.sh`), lands via PR        | Normal review + the `check` workflow                                |
| Build → sign → notarize → staple → DMG                | `build` job on `macos-26` (`scripts/release-build.sh`) | Signer-pin, Gatekeeper assessment, mount-and-verify (all in-script) |
| Tag, push, publish the GitHub Release                 | `publish` job (`scripts/release-publish.sh`)           | **Required reviewer on the `release-publish` environment**          |

The workflow is **dispatch-only**: a release is a deliberate act against one
reviewed commit, never a side effect of a push or a tag. Both jobs check out
`github.sha` — the exact commit the workflow was dispatched at — so the tag
cannot land on a commit other than the one that was built.

A dispatch from any ref other than `main` runs the build job and **stops**: the
publish job is skipped. That makes the signing and notarization path safe to
exercise as a dry run from a branch.

### The ship gate

The old flow installed the notarized build to `/Applications` and asked the
operator "continue?" — a human tested the real artifact before it was published.
The workflow keeps that gate as a **required reviewer on the `release-publish`
environment**: the publish job parks until someone approves it. Approve only
after downloading the DMG from the build job's run artifacts and installing it.
Nothing is rebuilt after approval, so what you test is byte-for-byte what ships.

### Trying main before you dispatch

The ship gate tests the artifact that is about to be published — late, and by
then a bug means bumping a patch. So every merge to `main` also gets an
installable build: the `check` workflow's `dev-build` job uploads
`blurt-dev-build-main-<short-sha>` for each commit that lands, kept 30 days.
Find it under Actions → **check** → the run for that commit; the run's summary
carries the download link and the four commands that install it.

Install and use that build before dispatching a release, and you are never
deciding from the diff alone. Two caveats on what it proves:

- It is a **`Debug-Local`, ad-hoc-signed** app, so it exercises behavior, not the
  signing/notarization path. Only the `build` job's DMG does that — which is
  exactly what the ship gate above still makes you install.
- A docs-only merge produces no build (the `changes` filter skips it, same as it
  skips `check`). Nothing that could alter the app changed, so the previous
  main build is still the current one.
- Merges that land back to back cancel each other's runs (`check` is
  `cancel-in-progress` on a ref), so an intermediate commit can end up without
  an artifact. The tip is what survives, which is the one you were going to
  release anyway.

## Required repository configuration

Two environments (Settings → Environments). They are what scope the secrets, so
neither is optional.

**`release-build`** — holds the signing and notary secrets. Restrict its
deployment branches to `main` so a fork or a stray branch can never reach the
Developer ID key.

| Secret                 | What                                                                                  |
| ---------------------- | ------------------------------------------------------------------------------------- |
| `SIGNING_P12_BASE64`   | Developer ID Application cert **and** private key, exported as `.p12`, base64-encoded |
| `SIGNING_P12_PASSWORD` | The export password for that `.p12`                                                   |
| `NOTARY_KEY_P8_BASE64` | App Store Connect API key (`.p8`), base64-encoded — the preferred notary credential   |
| `NOTARY_KEY_ID`        | That key's Key ID                                                                     |
| `NOTARY_ISSUER_ID`     | That key's Issuer ID                                                                  |
| `NOTARY_APPLE_ID`      | _Fallback only_ — Apple ID for notarization, if no API key is available               |
| `NOTARY_PASSWORD`      | _Fallback only_ — app-specific password for that Apple ID                             |

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

## A bad release: roll forward, never roll back

Blurt does **not** yank published releases. The update check only ever offers
users a strictly higher version (`UpdateChecker` compares `SemanticVersion` and
reports `.available` only when the latest tag is greater), so the fix for any bad
build is to **ship a new patch** via `scripts/release.sh`.

The one exception is a fault caught **before announcing**, while the same version
is still safe to overwrite (e.g. a corrupted upload flagged by the post-publish
verification step): dispatch the `release` workflow again with **`republish`
checked**, which deletes and recreates the tag and its release with fresh
artifacts. A code bug is never a republish — bump a patch.

```sh
gh workflow run release.yml --ref main -f version=X.Y.Z -f republish=true
```
