<div align="center">
  <picture>
    <source srcset=".github/images/blurt-logo-ansi.webp" type="image/webp" />
    <img src=".github/images/blurt-logo-ansi.png" alt="Blurt logo" width="720" />
  </picture>

  <h2>Blurt your first draft.</h2>

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
    height="435"
  />

</div>

## Download and install

1. [Download **Blurt.dmg**](https://github.com/AssemblyAI/blurt/releases/latest/download/Blurt.dmg).
2. Open the disk image and drag **Blurt.app** into `Applications`.
3. Launch Blurt and follow setup: Microphone, Accessibility, and your [AssemblyAI API key](https://www.assemblyai.com/dashboard/api-keys).
4. Start dictating with **right command** by default. Tap to toggle, or hold for push-to-talk.

## Why Blurt

- **Works anywhere you can type.** Blurt pastes the transcript into the focused Mac app.
- **No model downloads.** Audio goes to AssemblyAI's Sync STT API and comes back as text.
- **No extra cleanup step.** The polishing instruction rides with the transcription request.
- **Small native app.** The setup window, overlay, hotkey, and paste flow are built for macOS.
- **Actual synth cues.** Start and stop can be cued by real Yamaha DX7 or Roland Juno-106 sounds, or turned off.

## Requirements

| What           | Requirement                             |
| -------------- | --------------------------------------- |
| macOS          | macOS 15 Sequoia or later               |
| Mac            | Apple Silicon                           |
| Speech-to-text | AssemblyAI API key, free tier available |

## Privacy

Blurt stores your API key in the macOS Keychain. Audio is captured only while
you are dictating, then sent over HTTPS to AssemblyAI for transcription. Blurt
stores no audio and no transcripts.

Release builds send crash reports and a few handled errors to
[Sentry](https://sentry.io). Those reports are diagnostic only: stack traces and
error details, never your audio, transcripts, or API key.

Because transcription is processed by AssemblyAI, their policies apply to that
audio:

- [AssemblyAI Privacy Policy](https://www.assemblyai.com/legal/privacy-policy)
- [AssemblyAI Terms of Service](https://www.assemblyai.com/legal/terms-of-service)

## Build from source

Blurt is MIT-licensed. [`AGENTS.md`](./AGENTS.md) has the architecture notes and
build workflow.

```bash
scripts/bootstrap.sh   # install the local toolchain
scripts/dev-build.sh   # build + install Blurt to /Applications
scripts/check.sh       # full repo health check
```
