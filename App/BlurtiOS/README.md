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
- **They talk through an App Group** (`Shared/SharedState.swift`): payloads in the
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

## Testing in the simulator

Signing and the team don't matter here, and the App Group works, so the whole
loop runs. `AVCaptureSession` carries no audio in the simulator, so the app uses
`SimulatorAudioSource` (an Audio Queue on the Mac's microphone) there and
`WindowedAudioSource` on a phone.

```bash
cd App/BlurtiOS && xcodegen generate
xcodebuild -project BlurtiOS.xcodeproj -scheme BlurtiOS -destination 'generic/platform=iOS Simulator' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= build
xcrun simctl boot "iPhone 18 Pro" && xcrun simctl install booted <DerivedData>/Build/Products/Debug-iphonesimulator/BlurtiOS.app
xcrun simctl privacy booted grant microphone dev.alex.blurt.ios && xcrun simctl launch booted dev.alex.blurt.ios
```

Xcode 27 replaced Simulator.app with Device Hub (`Xcode.app/Contents/Applications/DeviceHub.app`);
turn off its **Always simulate hardware keyboard** setting or no on-screen keyboard appears.
Then: Blurt → Open Settings → Keyboards → Blurt on, Allow Full Access; Start listening;
in Notes, hold the globe key, pick Blurt, tap the mic.

## Testing on a phone

1. Install Xcode 26.6 or newer — the version CI builds with (`xcodes install 26.6 --select`, or
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

- **Sign in with AssemblyAI.** The shipping app signs the user in and gets a key
  behind the scenes; that service does not exist yet. Debug builds show "Use an API
  key instead" (`KeyEntryView`) so the pipeline can be tested now.
- **Returning to the host app.** After "Start Blurt" the user swipes back; iOS 26.4
  ended automatic switch-back for everyone.
- **The full keyboard** has no autocorrect or suggestions yet.
- **Interruptions** (a phone call) close the listening window; the user reopens it.

## What to verify on a phone first

The listening window's life in the background (capture keeps flowing after the
swipe back; battery over an hour); keyboard → app → back on iOS 26 and 27; the
keyboard's memory with the pill animating; how long the lexicon takes on a phone
with thousands of contacts; and, once the service exists, sign-in end to end.
