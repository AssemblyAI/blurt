<div align="center">
  <picture>
    <source srcset=".github/images/blurt-logo-ansi.webp" type="image/webp" />
    <img src=".github/images/blurt-logo-ansi.png" alt="Blurt logo" width="720" />
  </picture>

  <h2>Incredibly fast, accurate voice dictation by AssemblyAI</h2>

  <p>
    <strong>
      Open-source Mac dictation that turns speech into polished text in the app
      you're already using.
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
    <sub>Free app · Apple Silicon · Bring your own AssemblyAI API key</sub>
  </p>

<img
    src=".github/images/blurt.png"
    alt="Blurt's ready screen: tap or hold the hotkey, speak, and transcribed text is pasted into the focused app"
    width="760"
    height="460"
  />

</div>

## Install

1. [Download **Blurt.dmg**](https://github.com/AssemblyAI/blurt/releases/latest/download/Blurt.dmg).
2. Open the disk image and drag **Blurt.app** into `Applications`.
3. Launch Blurt and follow setup: Microphone, Accessibility, and your [AssemblyAI API key](https://www.assemblyai.com/dashboard/api-keys).
4. Dictate with **right command** by default. Tap to toggle, or hold for push-to-talk.

Blurt needs macOS 15 or later on Apple Silicon, plus an AssemblyAI API key
(free tier available).

## Why Blurt

- **Accurate.** Transcription runs on AssemblyAI's most accurate speech-to-text model.
- **Fast.** The model responds in under 100 ms, so text lands about as soon as you stop speaking.
- **Multilingual.** Works in 18 languages.
- **Works anywhere you can type.** Blurt pastes the transcript into the focused Mac app.
- **Polished in one step.** Audio goes to AssemblyAI's Sync STT API and comes back as clean text — no model downloads, no separate cleanup pass.
- **Small native app.** The setup window, overlay, hotkey, and paste flow are built for macOS.
- **Actual synth cues.** Start and stop can be cued by real Yamaha DX7 or Roland Juno-106 sounds, or turned off.

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

Blurt is MIT-licensed. [`AGENTS.md`](./AGENTS.md) has the architecture notes and
build workflow.

```bash
scripts/bootstrap.sh   # install the local toolchain
scripts/dev-build.sh   # build + install Blurt to /Applications
scripts/check.sh       # full repo health check
```

Want to build your own Swift dictation app from scratch? The pipeline —
mic capture, AssemblyAI Sync transcription, and paste-into-the-focused-app —
is a standalone, dependency-free Swift package you can embed:
[`BLURTENGINE.md`](./BLURTENGINE.md) is the developer guide.
