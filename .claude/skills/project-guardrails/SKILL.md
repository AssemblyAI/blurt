---
name: project-guardrails
description: Blurt's hard "don't do this" rules — architecture decisions that were made deliberately and reverted before. Load this before adding or changing engine/app/build/test code so you don't reintroduce something that was intentionally removed.
user-invocable: false
---

# Blurt guardrails

These are settled decisions. Don't reintroduce them; if a task seems to require
one, stop and ask the user first. This is the fast "don't" list; AGENTS.md's
"Settled decisions" table is the fuller reference and the source of truth.

Many of these are also enforced mechanically — `scripts/check-invariants.sh`
(run by `check.sh`, including `--portable`) greps for the constructs that give
each one away, so reintroducing one fails the health check rather than depending
on this list being read. Those rules also pin a verbatim slice of the bullet
they come from in this file, so rewording or deleting one fails the gate until
someone decides whether the rule survives the edit — edit these entries
knowing that, and fix the anchor in the same change. Treat that as a backstop, not the boundary: the rules
it can't express are still here, still binding, and the reasons in this file are
what let you tell an intended exception from a mistake. Never silence a finding
with `// invariant-ok:` to get a build green — that marker is for a line that is
genuinely correct, and reaching for it means it's time to stop and ask.

## Audio

- **No `AVAudioEngine` / `installTap` capture path.** `MicCapture` uses
  `AVAudioRecorder` with a **fresh recorder per session** on purpose — a
  long-lived engine bound its input graph to one device and went stale on a
  mic↔built-in switch (`-10868`, all-zero buffers). Keep recording to a 16 kHz
  mono 16-bit WAV (the Sync API's geometry) so `stop()` reads it back with no
  resample pass.

## Transcription pipeline

- **No streaming STT.** The AssemblyAI Sync API returns the full transcript in
  one response. Overlay goes "Transcribing…" → full text.
- **No separate LLM cleanup pass.** Cleanup rides in the same dictation request,
  as the `llm` block's `instruction` (`CleanupInstruction`). No LLM Gateway
  client, no `StylerProtocol`, no post-transcription styling stage.
- **No local models / model downloads.** Transcription is a remote AssemblyAI
  call. No on-device ASR/LLM, no model cache, no download UI.
- **There is no `config.prompt`.** `config.conversation_context`
  (`ConversationContext.turns`) replaced it. Don't add a prompt back: a custom one
  replaces the service's managed default _and_ makes the API ignore
  `config.language_code`.
- **The context turns carry the recent dictations + the prior chunk, and nothing
  else.** `ConversationContext.turns` reads exactly two fields of
  `TranscriptionContext` (`recentTranscripts`, then `priorText` last). The app
  name, window title, field label and selected text are captured for the paste
  path and the developer-mode log and stay on the machine; the hints that used to
  carry them were deleted, not gated. Don't widen the context back out, and don't
  route that context onto the request by another path.
- **Key terms are word boosting, not context text.** They ride
  `config.word_boost` as a flat array of strings (`KeytermsBoost`), fitted to that
  field's own 2048-character cap. Don't fold them back into the context as a
  `Keywords: a, b, c.` clause, and don't also send `keyterms_prompt` — the aliases
  are mutually exclusive, and `word_boost` is the name the dictation API's
  reference documents.
- Don't reintroduce a "remove filler words (um, uh, like)" directive —
  `universal-3-5-pro` ignores it; it was deliberately dropped, and there is no
  prompt field to put it in now.
- **Don't set a language — not a directive, and not `config.language_code`.**
  Pinning transcription to English hurt non-English speech. The API documents
  `language_code` as defaulting to `en`, but detection was measured to work with
  no language field and no prompt (Spanish, French, German and Japanese clips each
  came back in their own language). Adding one removes working detection;
  `KeytermsWireTests` asserts the config carries no language key.
- **Injection is always a clipboard paste** (save → write → ⌘V → settle →
  restore), degrading to "left it on the clipboard" when the target is lost. No
  keystroke-by-keystroke typing path, no length threshold.

## App shape

- **Dock app first — no `LSUIElement`, no menu-bar-_only_ mode.** Blurt has a
  `MenuBarExtra` status item (dictation indicator + hotkey discoverability menu,
  in `MenuBar/MenuBarScene.swift`) layered on the Dock icon. Keep the Dock icon
  as the guaranteed entry point: the notch can hide a status item on a crowded
  menu bar, so nothing may depend on it being visible. A menu-bar-_only_ variant
  (no Dock icon) was tried and reverted twice for that reason — don't drop the
  Dock icon or add `LSUIElement`.
- The dictation trigger is a **single lone key** — a lone modifier (right ⌘
  default), or an extra mouse button via the Custom option — home-
  grown via `CGEventTap` + `DictationKeyGate`. No `KeyboardShortcuts` package, no
  key+modifier chord, and never a keyboard key beyond the curated modifiers or
  the left/right mouse button: the tap is listen-only and swallows nothing, so
  those would type or click into the focused app. (F-keys were in the first cut
  of Custom and removed by maintainer decision.)
- **Updates are download-only** — check → open the DMG in the browser → the user
  installs it. The `mxcl/AppUpdater` dependency and its in-place self-updater
  were removed; don't reintroduce a self-replacing install path, a timer-driven
  poll, or anything that installs on the user's behalf. Checking automatically
  once at launch on a configured app (`AutomaticUpdateCheck`, ≤ once a day,
  silent unless a newer release exists) is the one automatic part, and it still
  ends in the same Download/Later alert. Extend `UpdateChecker` /
  `UpdateCheckModel`.

## Build / tests

- **Don't hand-edit `App/Blurt/Blurt.xcodeproj/project.pbxproj`** — it's
  generated from `project.yml`; edit that and run `xcodegen generate`. check.sh
  fails on pbxproj drift (a PreToolUse hook also blocks edits to it).
- The engine has **no external SPM dependencies** (Foundation/Security/
  AVFoundation/CoreAudio only). Don't add one to `Sources/BlurtEngine/`.
- Unit tests use **Swift Testing**, not XCTest (the `BlurtUITests` XCUITest
  bundle is the one exception — XCUIAutomation requires XCTest). **Never touch
  the real Keychain in tests** — `APIKeyStore` is the production item; use an
  isolated service like `KeychainStoreTests` does (or `InMemoryAPIKeyStore`), or
  you'll trigger Keychain password prompts and corrupt the real item's ACL.
- UI-test-facing strings (identifiers, window titles, launch arguments, sentinel
  keys) live once in `App/Blurt/Shared/UITestIdentifiers.swift`, compiled into
  both the app and the test bundle. Don't re-add mirrored copies in
  `BlurtUITests/`.
- Don't redirect the post-build install away from `/Applications` — TCC won't
  register apps in DerivedData/`/tmp`, so permission toggles never appear.
- Don't add backwards-compat shims for removed types.

## Notarization

- Every nested mach-o **and embedded framework** must be signed with the
  hardened runtime and a **secure timestamp** (`--options runtime --timestamp`),
  or notarization rejects the build. `release-build.sh` re-signs frameworks for
  this — don't remove it.
