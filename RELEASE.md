# Release runbook

Blurt is built, signed, notarized, and published **locally** from the
maintainer's Mac via `scripts/release.sh` (see the script headers for the
two-run bump→publish flow). This file covers the security-critical custody and
policy decisions that aren't obvious from the scripts.

## Signing key custody

The Developer ID Application key (`640A7F5A9754400D4A0491E7A6FB30542D907806`,
team `Y54ZB9JF63`) is the root of trust: Gatekeeper accepts anything signed with
it, so every published DMG must carry this signature. Protect it accordingly:

- Keep the private key **non-exportable** in the login keychain with a tight ACL
  (only `codesign` / the release scripts may use it). Never store a plaintext
  `.p12` on disk or in cloud sync.
- `scripts/release-build.sh` preflights that the identity is present
  (`security find-identity -v -p codesigning`) and refuses to build without it.

## Rotating the signing certificate

If the key is compromised (or the cert expires):

1. Revoke the Developer ID Application certificate in the Apple Developer portal.
2. Issue a new Developer ID Application certificate **on the same team**
   (`Y54ZB9JF63`).
3. Update `IDENTITY` in `scripts/release-build.sh` to the new cert's SHA-1
   (`security find-identity -v -p codesigning`).
4. Cut a fresh notarized release.

Rotating to a new cert **within the same team** (`Y54ZB9JF63`) is seamless for
users — Gatekeeper accepts any valid Developer ID from any team, and updates are
a manual DMG download (see [Updates in AGENTS.md](./AGENTS.md#updates)), so there
is no signing-requirement pin to break. A **team change** (new Team ID) is still
worth avoiding on principle and announcing, but it no longer strands existing
users the way the former in-app updater's team-pinned requirement did.

## Rotating the notary credential

The notary Apple-ID app-specific password lives in the `blurt-notary` keychain
profile (submit-only; it cannot sign). To rotate: revoke the old app-specific
password at appleid.apple.com, mint a new one, and re-run
`xcrun notarytool store-credentials blurt-notary --apple-id <you> --team-id
Y54ZB9JF63 --password <new-app-specific-password>`.

## A bad release: roll forward, never roll back

Blurt does **not** yank published releases. The update check only ever offers
users a strictly higher version (`UpdateChecker` compares `SemanticVersion` and
reports `.available` only when the latest tag is greater), so the fix for any bad
build is to **ship a new patch** via `scripts/release.sh`.

The one exception is a fault caught **before announcing**, while the same version
is still safe to overwrite (e.g. a corrupted upload flagged by the post-publish
verification step): use `scripts/release-publish.sh --republish` to replace the
artifacts on the same tag. A code bug is never a republish — bump a patch.
