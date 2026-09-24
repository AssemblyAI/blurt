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

CI builds it for the simulator on every PR (`check.yml`'s `ios-build` job). Running
on a phone needs Xcode with a team that can provision the App Group; every id in
`project.yml` (`dev.alex.blurt.ios`, `group.dev.alex.blurt`) is a placeholder
inherited from the Mac app and must become org-owned before the App Store.

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
