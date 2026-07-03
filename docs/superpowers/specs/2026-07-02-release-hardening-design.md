# Release Hardening — Design

Date: 2026-07-02
Status: Approved scope, pending spec review

## Goal

Harden Blurt's **local** release process (the `scripts/release*.sh` family) against
the failure modes that actually reach a Mac user, without moving the build into CI.

The macOS trust model does the heavy lifting already: every shipped DMG is signed
with the Developer ID cert, notarized, and stapled, and `mxcl/AppUpdater` enforces
same-signer on updates. So Gatekeeper already guarantees **authenticity** and
**integrity** of the artifact automatically. This work targets only the gaps Apple
does **not** cover.

## Scope (locked)

In scope — the non-redundant protections plus one near-free hygiene win:

1. **Signing-key custody** — protect/verify the Developer ID private key (the root
   of trust) and document revoke-and-rotate.
2. **Build integrity** — sign exactly the reviewed `origin/main` commit; stricter
   preflight; pinned dependencies recorded in provenance.
3. **Broken-build protection** — launch smoke test, post-publish asset
   verification, and a scripted rollback/yank.
4. **SHA-pin GitHub Actions** + Dependabot (cheap source-integrity hygiene).

Out of scope (explicitly rejected as redundant on macOS or as an architecture
change we don't want):

- **No** move to CI-built releases — the build stays on the maintainer's Mac.
- **No** detached minisign/cosign signature — redundant with the notarized
  Developer ID signature that macOS verifies automatically.
- **No** signed git tags — provenance for auditors, not consumed by end users.
- **No** 1Password / notary-credential change — the `blurt-notary` keychain profile
  stays as-is. The notary app-specific password is a low-impact, *submit-only*
  credential (it can't sign), and moving it to 1Password is operational hygiene,
  not a meaningful reduction in compromise risk; not worth the added dependency.
- No changes to the app/engine runtime, the transcription pipeline, or `check.sh`
  beyond what the items above require.

## Why these and not the others

| Measure | Does Apple already cover it? | Verdict |
|---|---|---|
| Developer ID sig + notarization + staple | Yes (authenticity + integrity, auto-checked) | Rely on it |
| Signing-key custody | No — Gatekeeper trusts anything signed with the key | **In** |
| Build == reviewed source | No — notary scans for known malware, not provenance | **In** |
| Broken-build (crash/corrupt) protection | No — "notarized" ≠ "works" | **In** |
| SHA-pin Actions | No — keeps poisoned code out of the source we sign | **In** (cheap) |
| Notary credential in 1Password | Partially (keychain profile) — marginal gain | Out (not worth it) |
| Detached artifact signature | Yes — Developer ID sig already binds identity | Out (redundant) |
| Signed git tags | N/A to end users | Out |

---

## Component designs

### 1. Signing-key custody (`release-build.sh` preflight + `docs/RELEASE.md`)

The Developer ID private key is the one credential whose theft lets an attacker
ship Gatekeeper-passing malware. We cannot stream it from elsewhere (`codesign`
needs it keychain-resident), so we verify posture and document custody.

- **Preflight check**: verify the codesigning identity exists and matches the
  pinned hash — `security find-identity -v -p codesigning` must list `$IDENTITY`;
  die with guidance if absent. (Catches "wrong Mac / key not present" before a
  long build.)
- **`docs/RELEASE.md`** (new runbook) — a "Signing key custody" section:
  - Key must be **non-exportable** with a tight keychain ACL (only `codesign` /
    the release script may use it); no plaintext `.p12` on disk or in cloud sync.
  - **Revoke-and-rotate procedure**: revoke the compromised Developer ID
    Application cert in the Apple Developer portal, issue a new one, update the
    `IDENTITY` SHA-1 in `release-build.sh`, and cut a fresh notarized release.
    Note the blast radius (a leaked key can sign malware until revoked; revocation
    invalidates future Gatekeeper acceptance of anything freshly signed with it).
  - The notary app-specific password lives in the `blurt-notary` keychain profile;
    note how to rotate it (revoke at appleid.apple.com, mint a new one, re-run
    `xcrun notarytool store-credentials blurt-notary …`).

**User benefit:** highest of the set — protects the root of trust Gatekeeper
relies on.

### 2. Stricter preflight / build integrity (`release.sh`, `release-build.sh`)

Guarantee the bytes we sign are exactly the reviewed `origin/main` commit.

- In `run_build_publish` (and mirrored as a guard in `release-build.sh`): after
  `git fetch`, assert `git rev-parse HEAD == git rev-parse origin/main`. Not just
  the version string (already checked) but the exact commit — refuses to build if
  HEAD is behind, ahead with unpushed local commits, or on a detached/other ref.
- Keep the existing clean-tree guard and the `build-info` `git:` SHA == HEAD check
  that `dmg_already_built` already enforces.
- Dependency integrity: `Package.resolved` is already hashed into
  `build-info.txt`. Add a guard that the resolved file is git-tracked and clean
  (drift would already fail `check.sh`, but we assert it at build time too so a
  release can never pin un-reviewed dependency revisions).

**User benefit:** high — closes the "notary happily signs a backdoored/tampered
build" gap.

### 3. Launch smoke test (`release-build.sh`, after staple)

A basic "the artifact actually runs" gate — notarization proves *not-known-malware*,
not *works*.

- After stapling the app bundle, launch the **signed Release** app with a bounded
  window: `open` it, poll that the process stays alive for ~5s, and assert no new
  crash report appears in `~/Library/Logs/DiagnosticReports` matching `Blurt`
  during the window; then quit it (`osascript` quit, fall back to `kill`).
- **Best-effort and skippable** (`--skip-smoke`): Blurt is a GUI app that wants
  Accessibility/mic and shows an overlay, so it can't be driven fully headless.
  The check only asserts "launched and didn't immediately crash." The primary
  functional gate remains the human `release-install.sh` install-and-test step
  before publish. The script logs exactly what the smoke test does and does not
  cover.

**User benefit:** moderate — cheap catch for a build that crashes on launch.

### 4. Post-publish verification (`release-publish.sh`, after release create/edit)

Confirm the asset users will download is byte-identical to what we built and
notarized (catches a truncated/corrupted/interrupted upload before you announce).

- New final step: `gh release download "$TAG"` the `blurt-<version>.dmg` and
  `Blurt.dmg` assets into a temp dir, recompute SHA-256, and compare against the
  local `SHA256SUMS` (for the versioned DMG) and the local `Blurt.dmg` hardlink.
- `xcrun stapler validate` the downloaded DMG.
- On mismatch, die with guidance to `--republish` (packaging-only fault) or yank.
  Clean up the temp dir via `trap`.

**User benefit:** moderate — ensures the download channel serves exactly the
verified artifact.

### 5. Rollback / yank (`scripts/release-yank.sh` + runbook)

A scripted way to pull a bad release from the update channel.

- `scripts/release-yank.sh <X.Y.Z> [--reason "..."]`:
  - Confirm prompt showing what will change.
  - Mark `v<version>` as **prerelease** and not-latest
    (`gh release edit v<version> --prerelease --latest=false`). `mxcl/AppUpdater`
    skips prereleases/drafts and serves the highest remaining version, so existing
    users stop being offered the bad build; the tag/release stays for forensics.
  - Re-point `--latest` at the previous non-prerelease release so
    `releases/latest/download/` links resolve to a known-good DMG.
  - Print next steps: ship a fixed patch via `scripts/release.sh`.
- Runbook guidance: **yank** (pull from the update channel, ship a new patch) vs.
  **`--republish`** (same version, corrected artifact — only safe for a
  packaging-only fault before wide install). A code bug always means yank + new
  patch.
- If any pure decision logic emerges (e.g. "pick previous good release"), extract
  it as a side-effect-free helper and unit-test it in `release.test.sh`.

**User benefit:** moderate/high — the only lever to stop a broken build from
propagating through auto-update.

### 6. SHA-pin Actions + Dependabot (`.github/workflows/*`, `.github/dependabot.yml`)

Keep third-party Actions from being repointed under us (mutable-tag risk),
protecting the source that becomes a signed release.

- Pin every `uses:` to a full commit SHA with a trailing `# vX` comment, across:
  - `check.yml`: `actions/checkout@v6` (×2)
  - `codeql.yml`: `actions/checkout@v6` (×2), `github/codeql-action/init@v4` (×2),
    `github/codeql-action/analyze@v4` (×2), `actions/cache@v6`
  - `pages.yml`: `actions/checkout@v6`, `actions/configure-pages@v6`,
    `actions/upload-pages-artifact@v5`, `actions/deploy-pages@v5`
  - SHAs resolved via `gh api` at implementation time.
- Add `.github/dependabot.yml` with the `github-actions` ecosystem (weekly) so pins
  get update PRs and don't rot. SPM ecosystem left out for now (engine is
  dependency-free; the app's lone `mxcl/AppUpdater` pin can be added later if
  desired) — noted, not done.
- `actionlint` (run by `check.sh`/`--portable`) must stay green on the pinned
  workflows.

**User benefit:** upstream/indirect — keeps poisoned code out of the source we
sign.

---

## Testing & verification

- **Pure helpers** (any yank decision logic): unit-tested in
  `scripts/release.test.sh` (sourced, side-effect-free — must not inherit `set -e`
  side effects at source time).
- **New/edited scripts**: pass `shellcheck`; workflows pass `actionlint` — both run
  by `scripts/check.sh --portable`.
- **IO-heavy steps** (smoke test, post-publish verify, yank): verified by an actual
  release, consistent with how the existing build/publish steps are validated.
  There are no unit tests for `gh`/`notarytool` calls.
- A dry run of the yank against a throwaway test release is recommended before
  relying on it in anger.

## Files touched

- `scripts/release-build.sh` — signing identity preflight, launch smoke test,
  `--skip-smoke`.
- `scripts/release.sh` — HEAD == origin/main preflight, `Package.resolved` guard.
- `scripts/release-publish.sh` — post-publish asset download + verify.
- `scripts/release-yank.sh` — new rollback script.
- `scripts/release.test.sh` — tests for any new pure helpers.
- `.github/workflows/check.yml`, `codeql.yml`, `pages.yml` — SHA pins.
- `.github/dependabot.yml` — new (github-actions).
- `docs/RELEASE.md` — new runbook (signing-key custody, rotation, yank vs.
  republish).
- `AGENTS.md` — brief pointer to the runbook and the yank/prerelease rationale.
