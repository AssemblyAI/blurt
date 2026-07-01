<div align="center">
  <picture>
    <source srcset=".github/images/blurt-logo-ansi.webp" type="image/webp" />
    <img src=".github/images/blurt-logo-ansi.png" alt="Blurt logo" width="720" />
  </picture>

  <h3>Hold a key. Speak. Get clean text.</h3>

[![Download](https://img.shields.io/badge/download-Blurt.dmg-ff2d8e?style=flat-square)](https://github.com/alexkroman/blurt/releases/latest/download/Blurt.dmg)
[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-00e0ff?style=flat-square)](https://github.com/alexkroman/blurt/releases/latest)
[![Powered by AssemblyAI](https://img.shields.io/badge/powered%20by-AssemblyAI-00e0ff?style=flat-square)](https://www.assemblyai.com)

  <img src=".github/images/blurt.png" alt="Blurt's ready screen: tap or hold the hotkey, speak, and cleaned-up text is typed into the focused app" width="760" height="435" />
</div>

Blurt is a small, open-source macOS dictation app — native, private, and cued by real Yamaha DX7 and Roland Juno-106 synths. Hold a key, speak, and clean text lands where your cursor already is. Bring your own [AssemblyAI API key](https://www.assemblyai.com/dashboard/api-keys) — that's the whole setup.

<div align="center">

[**⬇ &nbsp;Download Blurt.dmg**](https://github.com/alexkroman/blurt/releases/latest/download/Blurt.dmg)

</div>

## Install

Download **Blurt.dmg** from the [releases page](https://github.com/alexkroman/blurt/releases/latest), open it, and drag **Blurt.app** into `Applications`.

**Requirements:** macOS 15 (Sequoia)+ · Apple Silicon · an [AssemblyAI API key](https://www.assemblyai.com/dashboard/api-keys) (free tier to start).

On first launch the wizard walks you through it: grant Microphone + Accessibility, paste your key (it goes into the macOS Keychain), and pick a hotkey — default is **right ⌘**, tap to toggle or hold to dictate. Change anything later from Settings (⌘,).

## The sound

Start and stop are cued by a real **Yamaha DX7** or **Roland Juno-106** — the synths behind Prince, Depeche Mode, and Tame Impala, not a generic beep. Every factory voice from both ships as a selectable cue; pick one in Settings, or choose **None** for silence.

## Privacy

Almost everything stays on your Mac — the app and your API key (kept in the macOS Keychain). Audio is captured only while you're dictating — held to talk, or after a tap until you tap again — then sent over HTTPS to **AssemblyAI** to be turned into text and handed back. The cleanup rides along in that same request, so there's no extra service in the loop, and Blurt stores no audio or transcripts of its own.

For stability, release builds report crashes and a few handled errors to [Sentry](https://sentry.io). These reports are diagnostic only — stack traces and error details, never your audio, transcripts, or API key — and Blurt doesn't attach your IP address or other identifying data. Debug builds report nothing.

Because your speech is processed by AssemblyAI, their policies govern that data — worth a read if you're weighing it up:

- [AssemblyAI Privacy Policy](https://www.assemblyai.com/legal/privacy-policy)
- [AssemblyAI Terms of Service](https://www.assemblyai.com/legal/terms-of-service)

## Build

MIT-licensed — read it, fork it, file an issue. [`AGENTS.md`](./AGENTS.md) has the architecture notes and build workflow.

```bash
scripts/bootstrap.sh   # install the local toolchain
scripts/dev-build.sh   # build + install Blurt to /Applications
scripts/check.sh       # full repo health check
```
