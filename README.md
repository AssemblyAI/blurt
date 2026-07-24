<div align="center">
  <picture>
    <source srcset=".github/images/blurt-logo-ansi.webp" type="image/webp" />
    <img src=".github/images/blurt-logo-ansi.png" alt="Blurt logo" width="720" />
  </picture>

  <h2>Free, open-source dictation for your Mac</h2>

  <p>
    <strong>
      Hold a key, talk, and the words land in whatever you're typing. One tool,
      one job. No subscription, no account, no middleman — audio goes straight
      from your Mac to AssemblyAI with your own key, and you can read every
      line of code that sends it.
    </strong>
  </p>

  <p>
    <a href="https://github.com/AssemblyAI/blurt/releases/latest/download/Blurt.dmg">
      <img
        src="https://img.shields.io/badge/Download-Blurt.dmg-f32a91?style=for-the-badge"
        alt="Download Blurt.dmg"
      />
    </a>
  </p>

  <p>
    <a href="https://github.com/AssemblyAI/blurt/releases/latest">
      <img
        src="https://img.shields.io/badge/macOS-15%2B-00d8ef?style=flat-square"
        alt="macOS 15 or later"
      />
    </a>
    <a href="https://www.assemblyai.com">
      <img
        src="https://img.shields.io/badge/powered%20by-AssemblyAI-00d8ef?style=flat-square"
        alt="Powered by AssemblyAI"
      />
    </a>
  </p>

  <p>
    <sub>MIT licensed · No subscription · Signed &amp; notarized · Bring your
    own AssemblyAI API key</sub>
  </p>

<img
    src=".github/images/blurt.png"
    alt="Blurt's ready screen: tap or hold the hotkey, speak, and transcribed text is pasted into the focused app"
    width="760"
    height="625"
  />

</div>

Tap a key, speak, and clean text lands in whatever Mac app has focus — think
the built-in macOS dictation, but fast, accurate, and working everywhere you
can type.

To _blurt_ is to say something suddenly, without stopping to think — which is
more or less what this app lets you do to your Mac.

Built entirely native (AppKit + SwiftUI — no Electron, no web views). The whole
pipeline lives in **BlurtEngine**, a dependency-free Swift 6 package: mic
capture, one synchronous `POST` to
[AssemblyAI's dictation API](https://www.assemblyai.com), and a clipboard paste
into the focused app. No local models, no upload-then-poll job queue, no
background daemons — audio in, polished text out, one HTTP request per
utterance.

## Features

- **Works anywhere you can type** — the transcript is pasted into the focused
  app via a synthesized ⌘V, with your prior clipboard contents saved and
  restored around it. If the target app quit while you were speaking, the text
  stays on the clipboard instead of vanishing.
- **One key, no chords** — dictation is triggered by a single lone modifier
  (right ⌘ by default; right ⌥ and `fn` also available). Tap to toggle, hold
  for push-to-talk. The event tap swallows nothing: a lone modifier types
  nothing anyway, and combos like ⌘C pass through untouched.
- **Polished in one step** — each utterance rides to AssemblyAI's dictation API
  with a contextual prompt built from the focused app, window, and field, the
  text around your cursor, and your own key terms; the same call runs a
  server-side LLM cleanup (disfluencies out, punctuation fixed), so the text
  comes back already polished. No second request, no model downloads.
- **Fast** — the model responds in under 100 ms. Blurt pre-warms the HTTPS
  connection while you're still speaking and flips to "transcribing" at
  key-up, so text lands about as soon as you stop talking.
- **Accurate** —
  [30% fewer hallucinations than Whisper](https://www.assemblyai.com/docs/pre-recorded-audio/benchmarks)
  on AssemblyAI's published benchmarks.
- **Multilingual** — works in 18 languages, detected automatically, and you
  can code-switch mid-sentence.
- **Live feedback** — a floating overlay pill shows a real-time mic level
  meter and the pipeline phase; a menu bar indicator mirrors it from anywhere.
- **Actual synth cues** — start and stop can be cued by real Yamaha DX7 or
  Roland Juno-106 sounds, or turned off.
- **Guided setup** — a first-run wizard walks through Microphone permission,
  Accessibility trust, and your API key; the same window later hosts settings
  for the trigger key, key terms, and sound pack.
- **No surprises** — updates are manual (check → download the DMG yourself;
  no background auto-updater), and there's no telemetry of any kind.

## Requirements

- Apple Silicon Mac, macOS 15+ (macOS 26 recommended — enables the Liquid
  Glass UI)
- An [AssemblyAI API key](https://www.assemblyai.com/dashboard/api-keys)
  (free tier available)

## Install

1. [Download **Blurt.dmg**](https://github.com/AssemblyAI/blurt/releases/latest/download/Blurt.dmg).
2. Open the disk image and drag **Blurt.app** into `Applications`.

## Getting started

From a fresh install to dictated text in your editor:

1. **Launch Blurt** — the setup wizard requests Microphone and Accessibility
   permissions and asks for your
   [AssemblyAI API key](https://www.assemblyai.com/dashboard/api-keys).
2. **Click into any text field** — a document, a chat box, a terminal.
3. **Tap right ⌘ and speak** — the overlay pill shows the live mic level. Tap
   again to stop, or hold the key and release for push-to-talk.
4. **Read what you said** — the polished transcript is pasted at your cursor.
5. **Tune it** — open Settings to change the trigger key, add key terms
   (names, jargon, product words the model should get right), or pick a synth
   sound pack.

## Privacy

Blurt stores your API key in the macOS Keychain. Audio is captured only while
you are dictating, then sent over HTTPS to AssemblyAI for transcription. Blurt
stores no audio and no transcripts, and sends no telemetry — no crash
reporting, no analytics, no usage tracking.

Because transcription is processed by AssemblyAI, their
[Privacy Policy](https://www.assemblyai.com/legal/privacy-policy) and
[Terms of Service](https://www.assemblyai.com/legal/terms-of-service) apply to
that audio.

## Build from source

Blurt is MIT-licensed and needs only Xcode and Homebrew to build:

```bash
scripts/bootstrap.sh   # install the local toolchain
scripts/dev-build.sh   # build + install Blurt to /Applications
scripts/check.sh       # full repo health check — the same script CI runs
swift test             # engine unit tests only
```

`dev-build.sh` installs to `/Applications` on purpose: macOS won't register
Accessibility/Input-Monitoring permissions for apps living in build
directories, so the app needs a stable install path to be usable at all.
[`AGENTS.md`](./AGENTS.md) has the architecture notes and full workflow;
[`CONTRIBUTING.md`](./CONTRIBUTING.md) covers how changes land.

## Architecture

```text
Sources/BlurtEngine/     Swift 6 package owning the pipeline — no external dependencies
  Audio/                 MicCapture: fresh AVAudioRecorder per session, 16 kHz mono PCM,
                         live level meter; DX7/Juno-106 sound packs
  STT/                   AssemblyAITranscriber: one POST to dictation.assemblyai.com/transcribe
                         (STT + LLM rewrite) + TranscriptionPrompt contextual priming
  Pipeline/              DictationSession actor: press/release/cancel commands, phase
                         stream, auto-release before the API's recording cap
  Hotkey/                DictationKeyGate/Router: pure, unit-tested state machine for the
                         lone-modifier trigger (tap vs hold vs combo)
  Injection/             KeyInjector: save clipboard → paste via synthesized ⌘V → restore
  FocusCapture/          Accessibility reads of the focused app/window/field that prime
                         the transcription prompt
  Config/, Update/       Keychain API-key store, key terms, manual release check

App/Blurt/               AppKit/SwiftUI shell (Xcode project generated by XcodeGen)
  AppCoordinator.swift   the one place the engine is composed for the real app
  Hotkey/                DictationKeyTap: the CGEventTap feeding the engine's key gate
  Overlay/, MenuBar/     floating status pill, menu bar dictation indicator
  Wizard/                setup wizard + settings window
```

The engine is a standalone package you can embed to build your own dictation
app — mic capture, dictation-API transcription, and paste-into-the-focused-app behind
three protocol seams, fully stubbed in tests. [`BLURTENGINE.md`](./BLURTENGINE.md)
is the developer guide.

Latency note: perceived speed is mostly bookkeeping. `press()` warms up the
HTTPS connection and kicks off the focused-field context read without awaiting
either; `release()` claims the "transcribing" state before the recording is
even read back from disk — so the stop cue fires at key-up, not after I/O.
