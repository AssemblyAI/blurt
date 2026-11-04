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
on a phone needs Xcode with a team that can provision the App Group. The ids in
`project.yml` (`com.assemblyai.blurt.iphone`, `com.assemblyai.blurt.iphone.keyboard`,
`group.com.assemblyai.blurt.iphone`) are AssemblyAI's, so they register under the AssemblyAI team;
anyone building under another team changes them locally (see Testing on a phone).

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
app (`BlurtiOS/Sources`) and the keyboard (`BlurtKeyboard/Sources`) are the UI on top of it, drawn
with **`BlurtDesign/`**, the component library: the design tokens, type roles and brand colours,
and the pieces every screen is built from (card, page, form, eyebrow, button, wordmark, grain).

It is a static framework, so the app and the keyboard each link their own copy beside the
engine's, and its API is `package` (one `SWIFT_PACKAGE_NAME` across the project), not `public`:
nothing outside this project can see it, and periphery still reports what nothing uses. A
preview hands the model a `ThemeFace`, not a palette — the colours are the UI's
(`KeyboardModel+Palette.swift`).

## Unit tests

`scripts/ios-test.sh` runs `BlurtiOSTests` on a simulator (CI's `ios-build` job runs it after
the build): the core's logic — the App Group contract (key terms, stale snapshots, layouts),
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
Settings…) or no on-screen keyboard ever appears. Then: Blurt → Open Settings, and Apps → Blurt →
Keyboards → Blurt on, Allow Full Access (the simulator's Settings opens at its top level, not on
Blurt's page); turn the session on; in Notes, hold the globe key, pick Blurt, tap the
mic. The keyboard's crash logs, if any, land in `~/Library/Logs/DiagnosticReports/BlurtKeyboard-*`,
and `xcrun simctl spawn booted log show --last 5m --predicate 'process == "BlurtKeyboard"'`
shows its console.

Two environment variables shape the simulator's microphone in a debug build. They reach the
app through `simctl launch`, which forwards every `SIMCTL_CHILD_*` variable it finds, so
`SIMCTL_CHILD_BLURT_SIM_FAULT=refuseStart scripts/ios-sim.sh` sets one for the launch.
`BLURT_SIM_AUDIO_FILE=<path>` plays a 16 kHz mono 16-bit WAV into every utterance in place of
the Mac's microphone, so a probe dictates real speech with nobody speaking. `BLURT_SIM_FAULT`
makes the source fail the way a phone's microphone does (`SimulatorAudioSource+Fault.swift`),
with the same typed failures (`ListeningSourceFailure`) and events (`SourceEvent`), so the app's
and the keyboard's answers to each can be seen without a phone call. The timed ones count from
the moment the session turns on; the app's log lines for them say `(simulated)`.

| `BLURT_SIM_FAULT`       | What the microphone does                                                                                                                                                          |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `refuseStart`           | every start — turning the session on, a hold, a parked press — throws `configureFailed(-12782)`, the simulator's own capture error                                                |
| `refuseBackgroundStart` | the session turns on and holds; a parked press's start throws `backgroundStartRefused(561015905)`, iOS's `!rec`                                                                   |
| `silentFrames`          | every chunk is digital silence, so an utterance trips the 1 s silence watchdog (`silent`)                                                                                         |
| `interruptAfter:<s>`    | after `<s>` seconds the microphone is taken (`interrupted(audioDeviceInUseByAnotherClient)`: no frames, presses refused) and given back `<s>` seconds later (`interruptionEnded`) |
| `runtimeErrorAfter:<s>` | after `<s>` seconds the session dies (`runtimeError(-12782)`) and stays dead until the session is turned off                                                                      |
| `routeChangeAfter:<s>`  | after `<s>` seconds the route changes (`routeChanged(newDeviceAvailable, BluetoothHFP)`); nothing else changes                                                                    |

## Testing on a phone

`scripts/ios-device.sh` is the whole loop on a real iPhone, with Xcode's command-line tools
only — no Xcode window, no debugger — and the device gate a capture change runs before it
lands: `preflight → install → launch → dictate → pull → syslog --negative`.

Once: Xcode 26.6 or newer (a phone on iOS 27 needs Xcode 27, which needs macOS 26.6; see
Getting Xcode), then `sudo xcode-select -s /Applications/Xcode.app`,
`sudo xcodebuild -license accept`, `sudo xcodebuild -runFirstLaunch` (a phone needs no
`-downloadPlatform`), and `scripts/bootstrap.sh` for xcodegen. Sign in to Xcode with an Apple ID on
the org's team (Settings → Accounts): the App Group needs a paid team, a free Personal Team cannot
register one. The build signs on AssemblyAI's (`BLURT_TEAM`, default `B2VQF7Q2QY`); automatic
signing registers `com.assemblyai.blurt.iphone`, `com.assemblyai.blurt.iphone.keyboard` and
`group.com.assemblyai.blurt.iphone` under it on the first build, and fails if another team already
owns them. The phone: plugged in, unlocked, "Trust This Computer" accepted, Developer Mode on
(Settings › Privacy & Security). `BLURT_DEVICE` names it by UDID or name; the default is Neil's
iPhone 13.

1. `scripts/ios-device.sh preflight` — the phone is `available` in `xcrun devicectl list devices`,
   Developer Mode is on, it has been unlocked since it booted, whether Blurt is installed; then the
   checklist of what no script can see: Settings › Developer › Enable UI Automation, the Blurt
   keyboard on with Full Access (Settings › Apps › Blurt › Keyboards), an API key in Blurt. Exits
   non-zero naming what is missing.
2. `scripts/ios-device.sh install` — `xcodegen`, a Debug build for the phone with automatic signing
   (derived data in `$TMPDIR/blurt-device-dd-<checkout hash>`, one per checkout), then
   `devicectl device install app`. It replaces whatever Blurt is on the phone (same bundle id). On
   the phone, trust the developer app once (Settings › General › VPN & Device Management).
3. `scripts/ios-device.sh launch` — Blurt with `-BlurtDeveloperMode YES` (the engine then logs to
   `Library/Logs/Blurt`); any arguments you pass replace that. A locked phone is reported plainly:
   unlock it and run `launch` again. On a fresh install: **Paste your key** (or
   `DEVICECTL_CHILD_BLURT_DEBUG_API_KEY=<key> scripts/ios-device.sh launch`, which a Debug build
   takes from its environment), **Allow** sending your voice to AssemblyAI, **Allow** the microphone,
   then **Open Settings** › **Apps › Blurt › Keyboards** (a phone may open straight on Blurt's page):
   Blurt on, **Allow Full Access**.
4. Dictate: turn the **session** on, go to Messages or Notes, hold the globe key, pick Blurt, tap
   the mic — tap again to stop, or hold it while you talk; the words land in the field. Repeat at
   the waits the flow asks for, and try the other two layouts from the app's Keyboard picker (the
   keyboard reads the choice the next time it comes up). `scripts/ios-device.sh kill blurt` or
   `kill keyboard` ends either process mid-dictation (the relaunch and dead-keyboard flows).
5. `scripts/ios-device.sh pull <dir> --syslog` — Blurt's own logs under `<dir>/Logs` (none on the
   phone yet is not a failure) and the phone's system log into `<dir>/device.logarchive`
   (`--last 15m` by default). `log collect` needs root, so macOS asks for an administrator
   password: the one way to run it from a script without typing a password into the terminal.
6. `scripts/ios-device.sh syslog <dir>/device.logarchive --negative` — the negative system
   predicate every run asserts: no `start recording in the background` / `561145187` / `!rec` line
   naming Blurt; exit 1 with the lines when there is one. Without `--negative` it prints Blurt's
   own lines, the system's lines about it (SpringBoard, runningboardd, audiomxd) and any refusal,
   minus the usual noise; `--last` counts back from the archive's end.

`flows` and `check` — the scripted G1–G9 flows and their per-flow predicates — are stubs until
`DeviceFlows` lands with the device gate.

## What is still a stub

- **Autocorrect and the suggestion bar** on the full keyboard.

- **Sign in with AssemblyAI.** The shipping app will sign the user in and get a key
  behind the scenes; that service does not exist yet. Until it does, every build
  (TestFlight included) takes a pasted API key (`KeyEntryView`), as the Mac app does.
- **Returning to the host app.** After "Start Blurt" the user swipes back; iOS 26.4
  ended automatic switch-back for everyone.
- **The full keyboard** has no autocorrect or suggestions yet.

## What to verify on a phone first

The listening window's life in the background (capture keeps flowing after the
swipe back; battery over an hour); keyboard → app → back on iOS 26 and 27; the
keyboard's memory with the orb growing into the wave; how long the lexicon takes on a phone
with thousands of contacts; and, once the service exists, sign-in end to end.
