# Blurt for iPhone

The iPhone app and the keyboard it ships. Same engine as the Mac app
(`Sources/BlurtEngine`), a different shell, because iPhone leaves no other shape:

- **The app listens and transcribes.** iOS lets no keyboard use the microphone. The
  app opens the microphone while it is in front (the keyboard sends it there with
  `blurt://start`), keeps it open for a _listening window_ (`ListeningWindow`,
  default 15 minutes, extended by every dictation), and runs the engine's
  `DictationSession` over that always-on capture (`WindowedAudioSource`, which
  converts the phone's native audio to the 16 kHz mono PCM the dictation API wants).
- **The keyboard is a remote control.** It sends press / release / cancel with the
  text around the cursor (the same context the Mac reads through Accessibility),
  shows the phase the app publishes, inserts the words that come back through
  `textDocumentProxy`, and reads the phone's word list (`UILexicon`: contact names
  and text replacements) so names come back spelled right with no setup.
- **They talk through an App Group** (`BlurtiOSCore/SharedState.swift`): payloads in the
  shared defaults, Darwin notifications to wake each other. Full Access is what
  lets the keyboard reach the group — without it the keyboard still types, and says
  what it needs.
- **Three layouts, the user's choice**: a slim mic bar, a mic panel (the Wispr /
  Aqua shape), or a full keyboard with the mic as the main key. One keyboard
  target, one setting, one set of plumbing.

## Build

```bash
cd App/BlurtiOS && xcodegen generate     # the project is generated, not committed
open BlurtiOS.xcodeproj                  # scheme BlurtiOS builds and embeds the keyboard
```

CI builds it for the simulator on every PR (`check.yml`'s `ios-build` job). On a
Mac with only the Command Line Tools — no iOS SDK — `scripts/ios-typecheck.sh`
typechecks both targets against the Mac Catalyst frameworks with the same
flags, which catches the Swift 6 isolation errors before CI does. Running
on a phone needs Xcode with a team that can provision the App Group; every id in
`project.yml` (`dev.alex.blurt.ios`, `group.dev.alex.blurt`) is a placeholder
inherited from the Mac app and must become org-owned before the App Store.

## Design

`DESIGN.md` — the tokens, the orb, the meter, the three layouts, the
app's screens, all traced to the Mac app's sources, plus the gallery that renders every layout
and state for a screenshot and the launch flags that reach every app state.

## Getting Xcode

Any Xcode from 26.6 (CI's macos-26 runner has it) works; a phone on iOS 27 needs Xcode 27, which
needs macOS 26.6. The Mac App Store is one way. The other is Apple's developer site through
[`xcodes`](https://github.com/XcodesOrg/xcodes): Homebrew cannot build it without Xcode
already present (chicken and egg), so take the prebuilt binary —
`gh release download --repo XcodesOrg/xcodes --pattern xcodes.zip`, unzip, put `xcodes` on
`PATH` — then `xcodes install 27.0 --select`. It signs in with an Apple ID that has accepted
the Apple Developer Agreement at developer.apple.com/account; a company-managed Apple ID
(Apple Business Manager) cannot accept it and gets a 403, so use a personal one for the
download. The archive lands in `~/Library/Application Support/com.robotsandpencils.xcodes/`;
an 83 KB "xip" there is a saved error page, delete it and retry.

## Logic and UI

The iPhone code splits the way the Mac's does. **`BlurtiOSCore/`** is the logic — the App Group
contract, the keyboard's model and rules, the voice state, term packs, the relay injector — and
plays the part `BlurtEngine` plays for the Mac shell: no SwiftUI, no views, no audio (the keyboard
links it, and the keyboard never hears anything; `check-invariants.sh` enforces the last). The
app (`BlurtiOS/Sources`) and the keyboard (`BlurtKeyboard/Sources`) are the UI on top of it, with
`Shared/` holding what both draw with (design tokens, type, brand colours).

It is a static framework, so the app and the keyboard each link their own copy beside the
engine's, and its API is `package` (one `SWIFT_PACKAGE_NAME` across the project), not `public`:
nothing outside this project can see it, and periphery still reports what nothing uses. A
preview hands the model a `ThemeFace`, not a palette — the colours are the UI's
(`KeyboardModel+Palette.swift`).

## Unit tests

`scripts/ios-test.sh` runs `BlurtiOSTests` on a simulator (CI's `ios-build` job runs it after
the build): the core's logic — the App Group contract (`KeyTermList`, stale snapshots, layouts),
the keyboard's rules (sentence start, the double space, the term field, return labels, letter
rows) against a fake text field, the gate against the app's phases, the Darwin signals, term
packs — and what the UI builds on it (palettes, the voice element, the gallery). The engine's
own tests stay `swift test`. Anything with a rule in `DESIGN.md` should have a test here.

The suite holds the same gates as the engine's: warnings are errors, a plain run fails when
`BlurtiOSCore` drops below the engine's own line-coverage floor (`MIN_IOS_COVERAGE`, 88%, in the
script — raise it as coverage grows, never lower it to land a change), and CI's `ios-sanitizers`
job runs it again under ThreadSanitizer and AddressSanitizer (`BLURT_IOS_SANITIZER=thread` or
`address` locally). `scripts/ios-check.sh` runs the whole iPhone bar in one go — the tests and
the coverage gate, then `swiftlint analyze` and periphery over this project — and is what CI's
`ios-build` job and a local `scripts/check.sh` run. The views are not in that figure, as the Mac shell's aren't in the engine's:
they are checked on sight, through the gallery and the probe's screenshot flows.

## Testing in the simulator

Signing and the team don't matter here, and the App Group works, so the whole
loop runs (`scripts/ios-lib.sh` holds the one signing recipe and the simulator pick). `AVCaptureSession` carries no audio in the simulator, so the app uses
`SimulatorAudioSource` (an Audio Queue on the Mac's microphone) there and
`WindowedAudioSource` on a phone.

```bash
scripts/ios-sim.sh                          # generate, build, boot, install, grant mic, launch
scripts/ios-sim.sh --screenshot shot.png    # …and capture the screen
```

Xcode 27 replaced Simulator.app with Device Hub (`Xcode.app/Contents/Applications/DeviceHub.app`),
which the script opens; turn off its **Always simulate hardware keyboard** setting (Device Hub →
Settings…) or no on-screen keyboard ever appears. Then: Blurt → Open Settings → Keyboards →
Blurt on, Allow Full Access; Start listening; in Notes, hold the globe key, pick Blurt, tap the
mic. The keyboard's crash logs, if any, land in `~/Library/Logs/DiagnosticReports/BlurtKeyboard-*`,
and `xcrun simctl spawn booted log show --last 5m --predicate 'process == "BlurtKeyboard"'`
shows its console.

## Testing on a phone

1. Install Xcode 26.6 or newer — CI's runner has 26.6 (`xcodes install 26.6 --select`, or
   the Mac App Store). A phone on iOS 27 needs Xcode 27, which needs macOS 26.6. Then once:

   ```bash
   sudo xcode-select -s /Applications/Xcode.app
   sudo xcodebuild -license accept
   sudo xcodebuild -runFirstLaunch
   xcodebuild -downloadPlatform iOS      # only for the simulator; a phone needs no download
   ```

   `scripts/bootstrap.sh` from the repo root installs xcodegen and the linters if `brew` has not.

2. Sign in to Xcode with your Apple ID (Settings → Accounts) and note your team ID (the ten
   characters after the team's name). The App Group needs a paid team — a free Personal Team
   cannot register one, so use the org's team, not your own.
3. `cd App/BlurtiOS && BLURT_TEAM=<your team id> xcodegen generate && open BlurtiOS.xcodeproj`.
   Automatic signing registers `dev.alex.blurt.ios`, `dev.alex.blurt.ios.keyboard` and
   `group.dev.alex.blurt` under that team on the first build; it fails if another team already
   owns them.
4. Plug the phone in (Developer Mode on: Settings → Privacy & Security), pick it as the run
   destination, run the `BlurtiOS` scheme. On the phone, trust the developer app (Settings →
   General → VPN & Device Management). In the app: **Use an API key instead** (debug builds
   only), **Allow** the microphone, then **Open Settings → Keyboards**: turn on Blurt and
   **Allow Full Access**.
5. Back in the app, **Start listening**, then go to Messages, hold the globe key, pick Blurt,
   and tap the mic. Tap again to stop, or hold it while you talk. The words land in the field.
6. Try the other two layouts from the app's Keyboard picker; the keyboard reads the choice the
   next time it comes up.

## What is still a stub

- **Autocorrect and the suggestion bar** on the full keyboard.

- **Sign in with AssemblyAI.** The shipping app signs the user in and gets a key
  behind the scenes; that service does not exist yet. Debug builds show "Use an API
  key instead" (`KeyEntryView`) so the pipeline can be tested now.
- **Returning to the host app.** After "Start Blurt" the user swipes back; iOS 26.4
  ended automatic switch-back for everyone.
- **The full keyboard** has no autocorrect or suggestions yet.

## What to verify on a phone first

The listening window's life in the background (capture keeps flowing after the
swipe back; battery over an hour); keyboard → app → back on iOS 26 and 27; the
keyboard's memory with the orb growing into the wave; how long the lexicon takes on a phone
with thousands of contacts; and, once the service exists, sign-in end to end.
