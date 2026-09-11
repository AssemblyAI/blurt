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

- **No `AVAudioEngine` / `installTap` capture path.** `MicCapture` builds a
  **fresh `AVCaptureSession` recorder per capture** (`CaptureSessionRecorder`;
  owner-directed move from `AVAudioRecorder`, 2026-08-25) — a long-lived engine
  bound its input graph to one device and went stale on a mic↔built-in switch
  (`-10868`, all-zero buffers), so no recorder survives across a device change.
  Keep the data output converting to 16 kHz mono 16-bit S16LE (the Sync API's
  geometry), published straight onto the feed `start()` returns with no resample
  pass. **`stop()` answers a byte count, not the audio** (owner-directed,
  2026-09-08): the recording is uploaded in chunks as it is captured, so nothing
  downstream reads it back, and accumulating the blob as well copied every byte
  a second time inside the capture lock and held a duplicate of the whole
  utterance (~3.7 MB at the cap) until release. Don't reintroduce a buffered
  copy "just in case" — there is no retry-from-buffer path, by design.
- **Don't pre-open the mic to make presses feel faster.** `MicCapture.warmUp()`
  is stateless on purpose — build a session, drop it — and there is no warm or
  prepared recorder to reuse. Measured on hardware: building a session (or the
  retired `prepareToRecord()`) leaves the device closed and costs ~15 ms, while
  `record()`'s `startRunning()` opens it and costs 180–600 ms, so nothing can
  pre-pay the bring-up. A warm-recorder lifecycle was tried, and its
  device-identity check, pin check, 60 s expiry and bring-up flag all existed to
  protect ~15 ms. If you want the press to feel faster, the liveness gate's
  polling is where the remaining latency actually is.

## Transcription pipeline

- **No streaming STT.** The AssemblyAI Sync API returns the full transcript in
  one response. Overlay goes "Transcribing…" → full text. The route is named
  `/v1/transcribe/live` and the `config` part must precede the `audio` part, but
  that is about the **upload**: the service starts inferring as the audio
  arrives, and still answers with one final transcript. No deltas, no partial
  results, no WebSocket — don't read the route name as permission to add them.
- **No separate LLM cleanup pass.** Cleanup rides in the same dictation request,
  as `config.llm_instruction` (`CleanupInstruction`). No LLM Gateway
  client, no `StylerProtocol`, no post-transcription styling stage.
- **No local models / model downloads.** Transcription is a remote AssemblyAI
  call. No on-device ASR/LLM, no model cache, no download UI.
- **There is no `config.conversation_context`.** `config.stt_prompt`
  (`STTPrompt.text`) replaced it — one string, not an array of turns. Don't add
  the turn list back alongside: both fields work and ride the same request, so
  doing so puts the same prior text on the wire twice rather than failing. And
  never send `prompt`: it is `stt_prompt`'s other name, and a request carrying
  both is a 400 (`provide only one of stt_prompt or prompt; they are the same
field`).
- **The contextual prompt carries the recent dictations + the prior chunk, and
  nothing else.** `STTPrompt.text` reads exactly two fields of
  `TranscriptionContext` (`recentTranscripts`, then `priorText` last). The app
  name, window title, field label and selected text are captured for the paste
  path and the developer-mode log and stay on the machine; the hints that used to
  carry them were deleted, not gated. Don't widen the context back out, and don't
  route that context onto the request by another path.
- **Never send `config.prompt`.** It is `config.stt_prompt` under its legacy
  name — the docs list `stt_prompt` as the field and `prompt` as also accepted —
  and the two are mutually exclusive: a request carrying both earns `400 provide
only one of stt_prompt or prompt; they are the same field`, before the audio is
  read. Adding it alongside is not a compatibility shim, it is every dictation
  failing.
- **Key terms are keyterms prompting, not context text.** They ride
  `config.keyterms_prompt` as a flat array of strings (`KeytermsBoost`), fitted to
  that field's own 2048-character cap _and_ its 100-term `maxItems` — two caps on
  one field, and the count is reachable under the byte budget. Don't fold them back into the context as a
  `Keywords: a, b, c.` clause, and don't also send `keyterms` or `word_boost` —
  the three names are the same feature and mutually exclusive (400 before the
  audio is read), and `keyterms_prompt` is the canonical one. Sending `word_boost`
  instead was the shape until 2026-09-10; adding a second name is never a
  compatible change.
- **The dictation API's docs are the source of truth; call it only the way they
  describe.** Every path, header, multipart part, `config` key, response key and
  error key Blurt sends or reads is one the reference documents. This route has
  been renamed a lot, and it still answers to names the docs have dropped —
  `prompt`, `keyterms`, `word_boost`, `language_code`, and `llm: null` — so **a
  200 is not evidence a field is supported, only that it has not been removed
  yet.** Treat any name absent from the docs as deprecated and don't send it,
  however well it works today: it carries no compatibility promise, so a feature
  resting on it can stop working silently. Removed under this rule on 2026-09-11:
  `llm: null` (the only rewrite off switch — hence the response-side switch
  below), the `message` error field, and `warmUp()`'s GET at the bare host root
  (→ the documented `GET /warm`). Running _tighter_ than the docs is fine, and
  `STTPrompt.characterCap` deliberately does. Measuring is still how a claim gets
  settled — the docs have been wrong twice — but a measurement licenses
  distrusting a documented field, never sending an undocumented one.
- **Don't put the enhanced-transcripts switch back on the request.** Every
  dictation asks for the rewrite (`llm_instruction` always rides the config) and
  the switch picks between `llm_response` and `text` on the _response_
  (`AssemblyAITranscriber.transcript(from:)`). The route documents no way to
  decline: omitting `llm_instruction` only selects the service's own wording, and
  the one off switch that works — an explicit `"llm": null` — is undocumented.
  Blurt sent it until 2026-09-11. Adding an `llm` key back makes the response's
  choice unreachable.
- Don't reintroduce a "remove filler words (um, uh, like)" directive —
  `universal-3-5-pro` ignores it; it was deliberately dropped, and there is no
  prompt field to put it in now.
- **Don't set a language — not a directive, and not `config.language_codes`.**
  Pinning transcription to English hurt non-English speech. Detection was
  measured to work with no language field and no prompt (Spanish, French, German
  and Japanese clips each came back in their own language), and re-measured
  2026-09-11: a Spanish clip came back as Spanish with no field, with
  `language_codes: ["es"]`, **and** with `language_codes: ["en"]` — the field
  does not appear to constrain output on this route, so the reference's `["en"]`
  default does not describe the behaviour. Note the plural is the documented
  spelling, but the singular `language_code` is accepted too (a 200, not an
  unknown-key 400), so both are live and `KeytermsWireTests` pins both absent.
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
- The dictation trigger is a **single lone modifier** (right ⌘ default), home-
  grown via `CGEventTap` + `DictationKeyGate`. No `KeyboardShortcuts` package, no
  key+modifier chord.
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
