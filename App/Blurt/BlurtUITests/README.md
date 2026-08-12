# BlurtUITests

XCUITest integration suite for the Blurt app shell. It launches the **real app**
in a Debug-only UI-test mode and drives it the way a user would, asserting on
observable UI rather than mocking views.

## What's covered

- **Settings page** — `SettingsUITests`: the real Settings window's API-key flow
  (save / reject / reveal, and the change → cancel round-trip back to the saved
  row), the hotkey picker, and the sound picker.
- **Menu bar** — `MenuBarUITests`: the `MenuBarExtra` status item, its
  discoverability line, and the Open / Settings / Quit actions.
- **Recording audio** — `DictationPipelineUITests`: the harness drives
  `DictationSession` press/release — via both the real key tap and the direct
  Start/Stop seam — and asserts the live status walks to `recording` and back to
  `idle`, including two back-to-back runs to prove the pipeline re-arms.
- **Pasting into an app** — `DictationPipelineUITests`: the stub injector records
  what it would paste, with the harness window standing in for the target app.

## How it works

These tests don't need a microphone, the network, Accessibility permission, or
the real Keychain. Launching with `-BlurtUITest` (set by
`BlurtUITestCase.setUpWithError`) activates the harness in
`App/Blurt/Blurt/UITestSupport.swift` (`#if UITEST_HOOKS`), which:

- injects offline stub collaborators (`UITestMic`, `UITestTranscriber`,
  `UITestInjector`) and an `InMemoryAPIKeyStore` via the `DictationComponents` /
  `APIKeyGateway` seams on `AppCoordinator`, and
- presents a harness window with buttons that drive the same `DictationSession`
  the hotkey does (`press()` / `release()` / `cancel()`), plus read-outs for the
  live pipeline phase and the injector's last "paste".

The lone-modifier `CGEventTap` trigger can't be synthesized by XCUITest (and
needs an Accessibility-trusted process), so the harness drives the pipeline
directly; the tap → `DictationKeyGate` wiring is covered by the engine unit tests.

## Running

```bash
scripts/uitest.sh                 # just the UI suite (macOS + Xcode)
BLURT_INTEGRATION_TESTS=1 scripts/check.sh   # full health check, UI suite included
```

The suite drives the real app, so while it runs it owns the keyboard, the mouse,
and window focus — you can't use the Mac for anything else. That's why a plain
`scripts/check.sh` skips it and CI runs it on every PR instead; the two commands
above are how you ask for it deliberately.

## Maintenance

- Element lookups use `accessibilityIdentifier`s set in the app. The string
  constants live in `App/Blurt/Shared/UITestIdentifiers.swift`, which is compiled
  into both the app target and this bundle — declare any new identifier there so
  both sides agree by construction.
- After changing `App/Blurt/project.yml`, run `xcodegen generate` and commit the
  regenerated `project.pbxproj` (CI fails on drift).
