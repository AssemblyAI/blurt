# Building on BlurtEngine

BlurtEngine is the Swift package that powers [Blurt](../../README.md)'s dictation pipeline: capture speech from the microphone, transcribe it in a single AssemblyAI dictation API call (transcription plus a server-side LLM cleanup rewrite; the request carries the audio and nothing about the user's screen), and paste the polished text into the focused app. This guide is for developers embedding the engine in their own macOS app or extending it inside this repository. For repo-wide conventions and agent workflow, see [AGENTS.md](../../AGENTS.md).

## What you get

- **`Sources/BlurtEngine/`** — a Swift package (`swift-tools-version:6.2`, macOS 15+, Swift 6 strict concurrency) with **no external dependencies**: just Foundation, Security, AVFoundation, CoreAudio, toolchain modules like Synchronization, and AppKit types at the seams. That dependency-free rule is deliberate and enforced — don't add SPM dependencies to the engine.
- Pure logic behind three protocol seams (`MicCaptureProtocol`, `TranscriberProtocol`, `InjectorProtocol`), so every collaborator can be stubbed in tests and replaced in a host app.
- Production implementations of all three seams (`MicCapture`, `AssemblyAITranscriber`, `KeyInjector`), plus the supporting pieces a dictation product needs: Keychain-backed API-key storage, per-utterance contextual prompting (the text before the cursor, and nothing else about the user's screen), a hotkey state machine, permission checks, and UI-state projections.

What the engine does **not** contain: windows, overlays, menus, or event taps. Those live in the AppKit/SwiftUI shell (`App/Blurt/`), which composes the engine in exactly one place (`AppCoordinator`). If you're building your own host, you play the `AppCoordinator` role.

## Quick start

The library product is `BlurtEngine`, and `Package.swift` is at the repo root, so the engine is consumable as-is:

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/AssemblyAI/blurt", from: "0.1.39")
],
targets: [
  .target(name: "YourApp", dependencies: ["BlurtEngine"])
]
```

A local checkout works the same way with `.package(path: "../blurt")`. One thing to know before you pin a version: the tags are **Blurt's app releases**, minted by the DMG pipeline in [RELEASE.md](../../RELEASE.md), not independent engine releases — a patch bump says nothing about whether the engine changed. Read [Embedding outside Blurt](#embedding-outside-blurt) before shipping it inside another app.

Then compose a session:

```swift
import BlurtEngine

let session = DictationSession(
  mic: MicCapture(),
  transcriber: AssemblyAITranscriber(),
  injector: KeyInjector()
)

// Observe phase changes to drive your UI (see "Observing state" below).
Task {
  for await phase in await session.phaseStream() {
    render(phase.overlayState)  // or phase.menuBarStatus
  }
}

// Wire your trigger (hotkey, button, whatever):
await session.press()    // start recording
await session.release()  // stop → transcribe → paste
await session.cancel()   // abort, whatever the pipeline is doing

// Or, from a callback that can't await (an event tap, a UI action),
// use the synchronous fire-and-forget feed — same commands, same order:
session.submit(.press)
```

Before the first dictation can succeed the host must have:

1. **An AssemblyAI API key** saved via `APIKeyStore.save(_:)` (Keychain-backed; users create keys at `APIKeyStore.dashboardURL`) or through an injected `APIKeyGateway` (see below). Without one, transcription fails with `BlurtError.apiKeyMissing` — and if you pass a `readinessCheck` at init (e.g. `{ keyStore.hasKey ? nil : .apiKeyMissing }` over your `APIKeyGateway`), the press is refused _before any capture begins_ instead, so the user never records an utterance that can't be transcribed. Blurt passes exactly that check, and the engine's `OverlayUIState` projection renders the refusal as calm idle (not an error flash) so the host can route straight to its key-entry UI.
2. **Microphone permission** — check and request with `PermissionsChecker`.
3. **Accessibility trust** — required for the paste (`KeyInjector` posts a synthesized ⌘V) and for the focused-field context reads. `PermissionsChecker.check()` reports both; the app is ready once all permissions are granted and an API key is saved.

## The pipeline

```text
press() ──▶ MicCapture.start()            release() ──▶ MicCapture.stop() → Data (raw S16LE PCM)
            (16 kHz mono 16-bit PCM)                    AssemblyAITranscriber.transcribe(pcm:sampleRate:context:)
            + focus/context capture                     (one POST dictation.assemblyai.com/transcribe: STT + LLM rewrite)
            + connection warm-up                        KeyInjector.insert(text, after: priorText)
                                                        (clipboard paste via synthesized ⌘V)
```

Key properties of the design, which your integration can rely on:

- **One request per utterance, no streaming.** The dictation API returns the complete transcript — and its LLM-rewritten form — in the response body: no upload step, no job polling, no incremental deltas, no second request for the cleanup. `TranscriberProtocol.transcribe` is a single `async throws -> String`. UIs should show a "transcribing…" state and then the whole result; there is nothing to stream.
- **Cleanup happens server-side, and it's optional.** The request's `llm` block asks the service to apply our own cleanup instruction (`CleanupInstruction.text` — delete disfluencies, change nothing else) to the verbatim transcript inside the same call. It is one of three steering fields on the request: `config.conversation_context` primes the _transcription_ with the dialogue that came before — the user's recent dictations, then the text before the cursor (`ConversationContext`, omitted when there is neither) — and `config.word_boost` boosts the user's key terms (`KeytermsBoost`, omitted when there are none). There is no `config.prompt`; the context field replaced it. The block is gated by the **enhanced transcripts** setting (`EnhancedTranscriptsStore`, on by default): turned off, the config omits `llm` and the verbatim transcript is pasted as spoken. The **active style profile**'s instructions (`StyleProfileStore`, none by default) are appended to that instruction via `CleanupInstruction.sendable(appending:)`, trimmed to the headroom the API's 2048 instruction cap leaves (measured in UTF-8 bytes, the conservative bound — the cap's own unit is unmeasured); no profile, or blank instructions, means the base instruction goes out unchanged. Only the **active** profile's text is ever sent — never a join of the user's profiles, which would blow that cap and 400 the whole request rather than degrading. The engine pastes `llm_response`, falling back to the verbatim `text` when the best-effort rewrite failed (`llm_error`) — a degradation, never a user-facing error. There is no client-side LLM pass, no styling stage, and deliberately no hook for one.
- **Latency is pre-paid where possible, and never faked.** `press()` claims `.connecting` before it touches the mic, so a host's pill answers the keypress — but `MicCapture.start()` deliberately holds until the input device is actually delivering frames, and the _start cue_ waits for `.recording`. On a Bluetooth route those are ~1–2 s apart and the OS captures nothing in between, so cueing at the press loses the first words. `MicCapture` re-arms its prepared recorder after every capture so that route activation is usually paid between dictations rather than during one. `press()` fires a detached `warmUp()` at the transcriber (pre-opening the HTTPS connection while the user speaks, ~170 ms saved cold) and kicks off the cross-process accessibility read of the focused field without awaiting it — the read is then consumed at transcribe time with a bounded wait (`DictationSession.contextWaitBudget`, 500 ms), so an unresponsive frontmost app costs the transcript its priming, never a multi-second stall — and never delays the recording indicator. On the way out, `release()` flips the phase to `.transcribing` _before_ reading the recorded audio back, so a host's stop cue fires at key-up rather than after the disk read.
- **A held trigger auto-releases.** `DictationSession` stops recording after `maxRecordingSeconds` (default `SyncSTTLimits.autoReleaseSeconds`, 115 s) so audio never exceeds what the endpoint accepts, and transcribes what it has. Clips shorter than `SyncSTTLimits.minPCMBytes` (~100 ms of audio — an accidental tap) are dropped as a silent no-op rather than sent to earn a 400.

## DictationSession

`DictationSession` is the central actor. Everything the host does goes through four commands and one observation stream.

### Commands

- `press()` — start recording. Ignored unless the current phase is terminal (so a double-press is harmless). Refused up front — as `.failed(blocker)`, before the mic starts — when the host's `readinessCheck` returns a blocker.
- `release()` — stop recording and run transcribe → inject. Ignored unless recording.
- `cancel()` — the user's escape hatch. Works at every stage: over a recording it stops the mic and discards the audio; over an in-flight transcription or paste it tears the pipeline task down so nothing is injected. Cancels are honored deterministically even when they race a release mid-`mic.stop()` — the engine's serial command queue guarantees no transcript is pasted after a cancel.
- `cancelRecording()` — a narrower cancel for state-recovery callers (e.g. an event tap that got disabled mid-capture, or a trigger rebind): it only tears down a live _recording_ and never preempts a queued release or an in-flight pipeline, so a legitimately released transcript is never lost. Use `cancel()` for user intent; use `cancelRecording()` when _your plumbing_ lost track of the key state.

All four are `async` and queue internally; call them from any context without external locking.

For callback-shaped hosts that can't `await` — an event tap, a button action — there's also the synchronous, fire-and-forget **`submit(_: Command)`** (`.press` / `.release` / `.cancel` / `.cancelRecording`), which feeds a serial consumer inside the session. Commands submitted from one thread run in exactly the order they were submitted. This matters: spawning a `Task { await session.press() }` per callback carries **no** FIFO guarantee, so a recovery cancel could overtake the press it was meant to cancel and strand the recording. Blurt's `CGEventTap` wires its four callbacks straight into `submit`.

### Observing state

`phase` / `phaseStream()` expose the pipeline's `PipelinePhase`:

```text
idle → connecting → recording → transcribing → injecting → pasted | noTarget
                                     │              │
                                     └── failed(BlurtError) / cancelled (from any stage)
```

`connecting` is claimed the moment a press is accepted, _before_ the mic is up, so your UI can answer
the keypress instead of the hardware. It is **not** live capture: `MicCapture.start()` holds until the
input device actually delivers frames, which on a Bluetooth route takes ~1–2 s during which the OS
receives no audio at all. Present it as a warming-up state and **withhold your "speak now" cues** —
the recording indicator, the start chime — until `recording`, which follows only once audio is
genuinely being captured. Cueing at the press invites speech that nothing can capture.

- `phaseStream()` yields the current phase immediately, then every transition. It is a **multi-observer** stream: every call gets its own continuation and all of them see later transitions, so an extra consumer (a diagnostic, a second window) is safe. Still, prefer one renderer that projects the phase into your own state over a fan-out of long-lived consumers — one source of UI truth is easier to reason about than several.
- `.pasted` and `.noTarget` are terminal _success_ states, not errors. `.noTarget` means transcription worked but nothing editable was focused (or the target app quit), so the text was left on the clipboard — show a quiet "copied" notice, not a failure.
- Two ready-made projections keep UI mapping out of your shell: `phase.overlayState` (`OverlayUIState`: idle / connecting / recording / processing / error(message:) / pasted / noTarget, with accessibility labels and — for the transient notices — `noticeDwellSeconds`, how long to hold one before reverting to idle) and `phase.menuBarStatus` (coarser: idle / recording / transcribing, never shows errors, with `symbolName`/`accessibilityLabel` presentation — `connecting` rests at idle there rather than claiming a live mic).
- Pill geometry is available too, if you're drawing something like Blurt's overlay: `OverlayPlacement` resolves how big the panel is (`panelSize(pillSize:shadowMargin:)`, sized to hold the pill plus room for its shadow) and where it goes (clearance, clamping a dragged origin back on screen), and `MeterBarGeometry` gives the level meter its shape. Build a `MeterBarRow(availableSize:)` once per layout — it resolves how many bars fit and how tall they may be — then ask it for `height(at:level:time:animated:)` per bar; `MeterBarGeometry.breathingOpacity(time:period:minOpacity:)` is the pulse the record dot and status label share. All pure math; pass `animated: false` to honor Reduce Motion. `OverlayOriginStore` persists the origin the user drags the pill to — it lives here, beside the clamping it feeds, because two keys private to the AppKit controller escaped every reset sweep. Both components must be present to read back: `double(forKey:)` reports 0 for a missing key, so a half-written pair reads as "never moved" rather than pinning the pill to an implied origin.
- A "recent dictations" list has a model too. `RecentDictations` is an in-memory, newest-first ring of the last `capacity` (3) transcripts — never written to disk, empty at every launch — whose `record(_:style:at:)` takes an injected timestamp so tests are deterministic, plus the display name of the custom style the dictation was made with (`nil` for the base Default styling or with the rewrite off — those rows render just the time). `Entry.relativeLabel(now:locale:)` renders "just now" for the first `justNowThreshold` (60 s, published so a view can pick a refresh cadence against it) and the system's relative phrasing after. `reservedHeight(rowHeight:separatorThickness:)` is the `capacity` arithmetic — rows plus the `capacity - 1` separators between them — for a list that holds its height whether it shows 0 entries or 3.

### Record cues

`RecordingCueGate` is the other phase projection, and the reason the chimes don't retrigger: call `cue(for:)` with **every** phase and it returns `.start` only on the edge **into** `.recording` — in production the connecting→recording one, i.e. once the mic is actually delivering audio, never at the press — `.stop` only on the recording→not-recording edge, and `nil` while a phase repeats or when two non-recording phases follow each other. It's a value type holding one edge bit — keep a single instance for the host's lifetime.

Which chime plays is a `SoundPack`: an `id`, a display `label`, and the picker `group` it belongs to. `startFileName` / `stopFileName` give the `<id>-start` / `<id>-stop` stems, or `nil` for the silent `SoundPack.none`.

**The voices and the audio are both yours to supply.** The engine ships neither — no catalog, no `.m4a` files — because they are one artifact: a voice list whose stems name files that aren't in your bundle is a picker in which every choice plays silence, which is exactly what a package consumer used to get from the 192 entries that shipped here. Collect your voices into a `SoundPackCatalog`:

```swift
let catalog = SoundPackCatalog(
  voices: [SoundPack(id: "chime", label: "Chime", group: "Built-in")],
  defaultVoiceID: "chime")

let store = SoundPackStore(catalog: catalog)   // persists the id under <prefix>SoundPack
let pack = store.soundPack                     // or catalog.fromPersisted(rawIDFromAppStorage)
```

`groups` and `voices(in:)` build a sectioned picker off stored indexes rather than rescanning the list per render, and `fromPersisted(_:)` is the one decode-with-default rule (mirroring `TriggerKey.fromPersisted`) so a view reading the raw id can't disagree with `SoundPackStore`. A `defaultVoiceID` naming no voice resolves to `SoundPack.none` rather than trapping, and `SoundPack.none` stays reachable whatever you pass — a voice claiming that reserved id loses its own slot instead of taking away "no sound". `SoundPackStore` stays engine-side because its key is a `DefaultsKey` case, and that enum is the single roster `PersistedSettings.resetAll` sweeps.

Blurt's own catalog is generated into the _app_ target by `scripts/generate-sounds.swift` — 192 Yamaha DX7 (ROM1A/ROM1B) and Roland Juno-106 factory voices, written alongside the 384 `.m4a` cues they name, with `check.sh` failing if the two ever disagree. `CueSoundPlayer` resolves the stems against `Bundle.main`.

### Errors

Failures surface as `PipelinePhase.failed(BlurtError)`:

| Case                                   | Meaning                                                                                                                                                                                                                                          |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `.apiKeyMissing`                       | No AssemblyAI key stored — point the user at your key-entry UI. With a key-presence `readinessCheck`, this surfaces at press time, before any recording.                                                                                         |
| `.accessibilityPermissionMissing`      | Accessibility isn't granted, so the paste keystroke can't be posted; `PermissionsChecker` has openers for the right Settings panes.                                                                                                              |
| `.audioCaptureFailed(underlying:)`     | The mic couldn't start, or captured audio couldn't be processed. There is no separate microphone-permission case: a denied or revoked Microphone grant surfaces here, so check `PermissionsChecker` up front to catch it before the user speaks. |
| `.sttFailed(underlying:)`              | The dictation request failed; the underlying error carries the HTTP status and the server's message when available.                                                                                                                              |
| `.targetAppLost` / `.noEditableTarget` | Paste-side outcomes. When thrown by `KeyInjector` the transcript is already on the clipboard, and the session degrades them to `.noTarget` rather than a failure.                                                                                |

All cases are `LocalizedError` with user-ready `errorDescription` strings, and `BlurtError` is `Equatable` (wrapped errors compare by NSError domain + code), so phase equality is test-friendly.

## The three seams

`DictationSession`'s collaborators are protocol-typed. Swap any of them to change behavior; keep the contracts below.

### `MicCaptureProtocol` → `MicCapture`

```swift
func start() async throws
func stop() async throws -> Data        // raw S16LE mono PCM, 16 kHz, in order
func cancelCapture() async throws       // stop and discard; default: stop-and-drop
var levels: AsyncStream<Float> { get }  // 0…1 meter; default: empty stream
func warmUp() async                     // pre-open the device; default: no-op
```

Only `start()`/`stop()` must be implemented — `cancelCapture()`, `levels` and `warmUp()` have defaults, so a stub or headless capture conforms for free while hosts still read the meter and warm the device through the same seam they inject.

`cancelCapture()` is what the session calls when a dictation is cancelled, and it exists because the two teardowns want opposite things: `stop()` may legitimately spend time preserving the audio, while a cancel has nothing to preserve and must take effect at once. Override it only if stopping cheaply differs from stopping carefully in your capture.

`MicCapture` records with `AVAudioRecorder` straight to a temp 16 kHz / mono / 16-bit PCM WAV — exactly the geometry the dictation API wants — and reads it back as raw S16LE bytes on `stop()` (no float detour; the blob uploads as-is). A **fresh recorder per session** resolves the current default input device at `record()` time, which is why device switches (headset ↔ built-in) just work. Do **not** replace this with a long-lived `AVAudioEngine`/`installTap` graph: that design was tried, bound itself to one device, and failed with `-10868` or all-zero buffers on device switches.

`MicCapture`'s `levels` is a ~20 Hz meter of the recorder's dBFS power mapped to `0…1` (floored at −50 dBFS so room ambient reads as silence) — feed it to a voice-bars view; it costs nothing when unobserved. Its `warmUp()` pre-creates and prepares a recorder so the first `start()` skips hardware route discovery (Blurt calls it at launch, once mic permission is granted, so warming never triggers the permission prompt).

**Bluetooth inputs get four accommodations**, because opening the mic on AirPods makes the system renegotiate the link into its mic-capable mode — one to two seconds, during which the OS receives no audio at all — and that link then buffers audio.

The load-bearing one is that **`start()` doesn't return until the input is live.** `record()` returning `true` only means the AudioQueue started, so `start()` polls the recorder until its clock has advanced past 0 **and** its meter reads above `MicLiveness.silenceFloorDB` — the clock alone advances over the all-zero buffers a stale or not-yet-switched device delivers, so it confirmed a route that was still renegotiating. The floor separates _digital_ silence from any real analog input, not speech from quiet. The wait is capped per transport by `MicLiveness` (2.5 s Bluetooth, 300 ms on a recognised local transport, 1 s for an aggregate/virtual/unreadable one) and **fails closed** on timeout: `start()` tears the recorder down and throws `.audioCaptureFailed`, which the session surfaces as the same error pill as any other capture failure — never a recording the mic wasn't delivering for. Speech during the switch is not recovered by this — nothing receives it — the point is to stop inviting it.

The other three reduce how often that wait is paid, and fix the tail. `MicCapture` re-arms the warm recorder after _every_ capture rather than only at launch (the cost is per session, paid at `prepareToRecord()`); it records which device the warm recorder was built against and discards it when the default input has changed, since `AVAudioRecorder` resolves its device once and never re-resolves; and it releases an unused warm recorder after 60 s, because holding the input device open is what pins AirPods in the profile where output audio is degraded. On top of that, `stop()` keeps capturing for a further 220 ms when the input is Bluetooth, so speech still travelling over the link lands in the file instead of being truncated — the missing last word. `cancelCapture()` skips both that linger and the file read-back.

### `TranscriberProtocol` → `AssemblyAITranscriber`

```swift
func transcribe(pcm: Data, sampleRate: Int, context: TranscriptionContext?) async throws -> String
func warmUp() async   // optional; no-op default
```

`AssemblyAITranscriber` is a stateless `Sendable` struct. One `POST https://dictation.assemblyai.com/transcribe` per utterance: the audio as raw S16LE PCM (the `pcm` blob, byte-for-byte) in the `audio` multipart part, plus a JSON `config` part (`sample_rate`, `channels`, the rendered `prompt` (nil today, so the field is omitted), and — while enhanced transcripts are enabled, the default — an `llm` block whose one `instruction` field carries `CleanupInstruction.text`, with any custom style instructions appended — `CleanupInstruction.sendable(appending:)`), with the API key in `Authorization` (no model header — the service pins the STT model server-side). The response carries the verbatim `text` and the rewritten `llm_response`; the transcriber returns the rewrite and falls back to `text` when it is null (the rewrite is best-effort — `llm_error` is logged, never surfaced as a failure). Its initializer takes an `apiKeyProvider` closure (defaults to `APIKeyStore.current`), a `baseURL`, an `HTTPTransport` — inject a fake transport (see `Tests/BlurtEngineTests/Stubs/FakeHTTPTransport.swift`) to test against canned responses — an `enhancedTranscripts` closure deciding, per request, whether the `llm` block is sent (nil, the default, reads `EnhancedTranscriptsStore`), and a `customStyle` closure supplying the style instructions appended to the cleanup instruction (nil, the default, reads the active profile from `StyleProfileStore`). `warmUp()` fires a throwaway GET at the host root to pre-pool the connection; it never throws and any failure just means the real request pays connection setup as before.

The model's limits live in `SyncSTTLimits` (16 kHz sample rate, ~0.1 s–120 s audio, and the auto-release math — the sync STT model behind the dictation service) — the single source shared by the mic, the session, and the request so recorded and declared geometry can't drift.

### `InjectorProtocol` → `KeyInjector`

```swift
func setTargetApp(_ app: NSRunningApplication?) async
func insert(_ text: String, after priorText: String?, windowTitle: String?) async throws
```

`KeyInjector.insert` **always** pastes: it saves the current pasteboard, writes the transcript, activates the captured target app, posts a synthesized ⌘V, waits for the target to read the clipboard (`pasteSettleDuration`, default 400 ms, tunable in the initializer), then restores the prior pasteboard contents. That restore never destroys what it can't put back: an unreadable pasteboard snapshots as `nil` (not as empty) and is skipped, and the replacement items are built before `clearContents()`, with the plain-string flavor as a floor when promised representations can't be materialized. There is no keystroke-by-keystroke typing path and no length threshold. If the target app is gone or nothing editable is focused it leaves the text on the clipboard and throws `.targetAppLost` / `.noEditableTarget` — which the session turns into the quiet `.noTarget` outcome. AX-opaque targets — Electron editors and web browsers, per `FocusCapture.isAXOpaqueApp` — are exempt from the editability gate and are pasted into even with no editable AX signal: web content is routinely invisible to Accessibility (Chromium builds its tree lazily; `contenteditable` composers expose no editable role), so "no signal" there usually means "AX can't see the field," not "no field," and the accepted trade-off is a rare beep over dropping the user's words to copy-only. `priorText` (the text before the caret, captured at press time) drives `withLeadingSeparator`, which joins consecutive dictations with a space so they don't run together. When `priorText` is unreadable (an Accessibility-opaque editor, or a browser tab like Google Docs whose canvas-rendered body exposes no AX text), `separatorBasis` falls back to what was last pasted — but only when both the target app **and** `windowTitle` match the last successful insert, so the fallback tracks "the same window," not just "the same process" (a browser hosts many unrelated tabs/documents under one PID).

The session calls `setTargetApp` at press time with the app that was frontmost when recording started — so the paste lands where the user was, even if focus moved during transcription.

## Context and prompting

**Most of what is captured never leaves the machine.** The request's transcription prompt carries one context signal — the text immediately before the cursor — and the rest of the focus snapshot is collected for local work (paste spacing, the injector's window identity, the developer-mode log). The user's key terms are sent too, but on their own field rather than in the prompt. Hosts don't call these APIs directly, but should know what's collected, what it's for, and which part is sent:

- **`TranscriptionContext`** carries the frontmost app name, window title, focused-field label, the text before the caret, the selected text (which a paste will replace), and the user's key terms — of which two are sent: `priorText` (as the prompt) and `keyTerms` (as the word-boost list). It's captured via Accessibility at press time (skipped in secure fields), off the hot path — and consumed at transcribe time with a bounded wait (`DictationSession.contextWaitBudget`), so a hung read is abandoned rather than stalling the transcript. Of the focus signals only `priorText` is sent; the app name, window title, field label and selected text stay local — the injector reads `priorText`/`windowTitle` to decide the paste's leading separator and to recognize the captured window, and the developer-mode log records the rest.
- **`ConversationContext.turns(context:)`** renders the prior dialogue into the dictation request's `config.conversation_context` (transcription steering only — the cleanup rewrite is the separate `llm` block): an ordered array of strings, the user's recent dictations oldest-first (at most `recentTurnCap`, 99) followed by the text before the caret as the last turn, fitted to the API's 4096-character cap by dropping the oldest turns first. It reads no other field of the context. A context with neither history nor prior text yields `[]`, which omits the field so the model works from the audio alone. A history turn the prior chunk already ends with is dropped rather than sent twice — after a paste the field contains what was just dictated. **There is no `config.prompt`**: it carried this same prior chunk as prose under a `Previous transcript:` heading, and a custom prompt both displaces the service's managed default and makes the API ignore `config.language_code`. Two deliberate omissions survive from it, both regression-tested: no language steering (pinning to English hurt non-English speech) and no "remove filler words" clause (not in the model's trained instruction set — a no-op). The language one now covers `config.language_code` as well, and the request sets no language at all: detection was measured to work with neither field present (Spanish, French, German and Japanese clips each came back in their own language), so adding one removes working behaviour. Don't reintroduce either, and don't widen the context back out to the app/window/field hints the prompt used to carry.
- **`CleanupInstruction.text`** is the other half: the string sent as `config.llm.instruction`, which the service applies to the verbatim transcript with its own rewrite model. It is the winner of a GEPA run of `evals/dictation-prompt/`, compressed to fit the API's **2048-character** cap on that field — a different, smaller limit than the 4096 on `config.conversation_context`, and one that rejects the entire request rather than degrading (the context cap merely trims), so `CleanupInstruction.characterCap` is asserted in tests. Treat it as a measured artifact: a new hypothesis belongs in that harness plus a fresh run, not a hand-edit. Two caveats ship with it — it has only ever been scored against other text candidates on a stand-in model, never against the empty `llm` block on the service's own rewrite model, and every corpus behind it is English. Dropping the field restores the service default in one line.
- **`KeytermsBoost.fitted(_:)`** turns those terms into the request's `config.word_boost` — word boosting, the other steering field next to `conversation_context`, and a flat array of strings rather than prose. It takes whole terms in the user's order while they fit the field's own **2048-character** cap (`KeytermsBoost.characterCap`, in UTF-8 bytes — a third limit, distinct from the 4096 on `config.conversation_context` and the 2048 on `config.llm.instruction`), and returns a plain `[String]`; an empty result omits the field on the wire rather than sending `[]`. `word_boost` is the name the dictation API's own reference documents for this parameter — `keyterms_prompt` is what the sibling Sync STT surface calls the same feature, and the aliases are mutually exclusive, so send one and never both. Don't fold key terms back into the context as a `Keywords:` clause; that was the older, worse shape for the same intent.
- **`KeyTermsStore`** persists the user's domain vocabulary (names, jargon) in `UserDefaults`; `DictationSession` re-reads it at every press via its `keyTermsProvider` closure, so Settings edits apply to the next utterance without rebuilding the session. Pass your own provider to source terms from elsewhere. Its `parse` is the whole normalization (trim, drop blanks, dedupe case-insensitively) — `KeytermsBoost` assumes that and only enforces length.

For key storage, compose against **`APIKeyGateway`** — the injectable `current` / `save(_:)` / `hasKey` seam over the key store. `ProductionAPIKeyStore` forwards to the Keychain-backed `APIKeyStore`; `InMemoryAPIKeyStore` is a ready-made in-memory conformance for tests and harnesses (Blurt's XCUITest runs use it so the real Keychain item is never touched, and its `hasKey` backs the session's `readinessCheck`). For a settings UI, **`APIKeySubmission`** wraps the gateway with the validate-then-save flow (`submit(_:)` → valid / invalid / unreachable / saveFailed, via `APIKeyValidator`): it saves only a key AssemblyAI actively accepts, so an unverified key never persists. Two projections keep the surrounding UI out of your views: `Outcome.failureReport` classifies a failure as `.inline(message:)` (recoverable — show it beside the field) or `.alert(title:message:)` (a Keychain fault retyping can't fix), and **`APIKeyDisplay.resolve(key:)`** renders the stored key for an account row — masked tail, status and VoiceOver wording, and the connect-vs-rotate control titles. The mask reveals only the last `revealedTailLength` characters and, below `minimumLengthToMask`, none at all, so a short key can't be shown whole.

Setup gating has a projection too: **`SetupReadiness.isReady(permissions:hasAPIKey:)`** is the "fully configured" rule (deliberately excluding the trigger key, which has a default), `SetupReadiness.pollInterval(isReady:)` is the permission-poll cadence (brisk during setup, coasting once ready), and `PermissionStatus.lostGrant(since:)` detects a permission revoked out from under a configured app.

Accessibility grants carry one more wrinkle worth inheriting rather than rediscovering. macOS keys the grant to the app's _designated requirement_, so when what that requirement pins changes, the grant is orphaned — the "toggle is on, still denied" state. **`SigningIdentityMigration`** is the pure decision (persisted identity, current identity, live trust state, and the reset side effect all injected) and **`SigningIdentity`** the thin adapter that reads what a grant taken right now would pin: the **Team ID** for team-signed builds, so certificate rotation inside a team keeps the grant, and the **cdhash** for ad-hoc ones, where every build is a new app to `tccd`. Without the migration, a reviewer installing a second ad-hoc dev build finds the app already switched on in System Settings and can never satisfy the wizard, because that row belongs to the previous build's signature. Its defaults key is deliberately _outside_ the settings roster below — it records what a migration already did, and a settings reset must not forget it.

Each completed dictation is appended to **`DictationLog`** (a local JSONL history at `~/Library/Logs/<your logDirectoryName>/dictations.jsonl` — `DictationLog.defaultURL`, or `defaultDisplayPath` for the home-abbreviated form to show in UI) with its context snapshot — but only while developer mode is switched on. Each _failed_ dictation is appended to a sibling error log at `errors.jsonl` in the same directory (`defaultErrorDisplayPath` for the UI form) behind the same switch: one line per failure with the stable `BlurtError` case label, the full description (which for `.sttFailed` carries the API status and server message), and the focused app/window/field — but no prior text, selected text, or prompt, since none of it explains a failure. The two logs are separate files so the dictations log stays a corpus whose every line carries a `transcript`. **`DeveloperModeStore`** persists that opt-in in `UserDefaults` (`BlurtDeveloperMode`, off by default); with it off, nothing is written to disk. Blurt surfaces the switch (and both log paths) in the Settings window's Developer section.

## Settings and persistence

Every user setting is a small `UserDefaults`-backed struct with the same shape: a public `defaultsKey` (so a SwiftUI view can bind `@AppStorage` straight to it and re-render live on a Settings change), an injected `UserDefaults`, and a decode-with-default rule owned by the store rather than restated in the views.

Keys are the host identity's `defaultsPrefix` followed by the `DefaultsKey` case's raw value; the table shows them under the default `.blurt` identity.

| Store                      | Key                              | Unset means                       |
| -------------------------- | -------------------------------- | --------------------------------- |
| `TriggerKeyStore`          | `BlurtTriggerKeyCode`            | right ⌘                           |
| `SoundPackStore`           | `BlurtSoundPack`                 | the catalog's `defaultVoiceID`    |
| `KeyTermsStore`            | `BlurtKeyTerms`                  | no key terms                      |
| `DeveloperModeStore`       | `BlurtDeveloperMode`             | off — nothing is logged to disk   |
| `EnhancedTranscriptsStore` | `BlurtEnhancedTranscripts`       | **on** — the `llm` block is sent  |
| `StyleProfileStore`        | `BlurtStyleProfiles`             | no style profiles defined         |
| `StyleProfileStore`        | `BlurtActiveStyleProfile`        | the first defined profile         |
| `StyleProfileStore`        | `BlurtCustomStyle`               | the pre-profiles field, read-only |
| `OverlayOriginStore`       | `BlurtOverlayCustomOriginX`/`…Y` | pill never dragged; default place |
| `LastUpdateCheckStore`     | `BlurtLastUpdateCheck`           | never checked                     |

Several are read-only by design (`KeyTermsStore`, `DeveloperModeStore`, `EnhancedTranscriptsStore`): the Settings control binds `@AppStorage` to `defaultsKey` and is the sole writer, so normalization lives on the read side — a whitespace-only key-terms field reads back as "no terms" — and a setter here would fight the text field. `StyleProfileStore` is the counter-case: its value is JSON, so the encoding is the store's to own and the views write through it (`profiles`, `activate(_:)`, `activateDefault()` — the last stores a sentinel meaning "base styling, no profile appended", distinct from unset so a migrated legacy profile stays active) while binding `@AppStorage` only to observe. It also still **reads** `BlurtCustomStyle`, the single field that predates profiles, and never writes it — an install with text there and no list reads back as one active profile named "Custom". The five a host constructs itself (`TriggerKeyStore`, `SoundPackStore`, `StyleProfileStore`, `OverlayOriginStore`, `LastUpdateCheckStore`) take a `UserDefaults` publicly; the rest keep that injection internal. (`SoundPackStore` also takes the `SoundPackCatalog` it decodes against — see [Record cues](#record-cues).)

The keys themselves are one internal `DefaultsKey` enum and each store reads its case from it, so **`PersistedSettings.resetAll(in:)`** sweeps `DefaultsKey.allCases` rather than a hand-maintained list — adding a store and adding it to the reset are not merely the same edit, they're the same line. That's not tidiness: it _was_ a hand-maintained array, and both times a store was copy-edited into existence the second half was forgotten (the overlay origin and the update-check stamp), so a pill dragged during a UI-test run survived `reset-install.sh`'s clean-install path into the next one. Raw values are half the on-disk contract and the identity's `defaultsPrefix` is the other — rename a case freely, never its raw value or your prefix, or every existing user's setting is silently abandoned.

**`InstallReset`** is the whole-install sweep behind Blurt's Settings → Advanced → Reset button: `PersistedSettings.resetAll()`, the API key deleted through the host's own `APIKeyGateway` (so a UI-test run clears its in-memory store, not the real Keychain item), `PermissionsReset.resetAll(bundleID:)` over the three TCC services an install holds grants under (`Accessibility`, `Microphone`, and Input Monitoring's internal `ListenEvent`), and `DictationLog.removeStoredLogs()`. Pass the **running** bundle id — `Bundle.main.bundleIdentifier`, never `HostIdentity.current.subsystem`, or a debug build clears the shipping app's grants. No step short-circuits the ones after it: `run()` returns `nil` when the install came out clean (Blurt's shell restarts the app on that — TCC prompts once per process, so only a process started after the sweep is asked again) or an `AlertContent` naming what survived, wording owned here for the same reason `UpdateAlertContent` is. It is the in-app half of `scripts/reset-install.sh`; the only thing the script does that this can't is unregister _other_ copies of the app from LaunchServices.

Two string helpers carry the "usable text" rule shared by focus capture, the context/prompt, and the stores: `trimmedNonEmpty()` (on both `String` and `String?` — trims surrounding whitespace, treats blank as absent) and `prefix(maxUTF8Bytes:)`, which drops whole `Character`s from the end so a multi-scalar emoji is removed intact rather than sliced into an invalid fragment. The latter is the single truncation rule behind the custom-style budget, shared by the Settings field's counter and `CleanupInstruction.sendable(appending:)` — the two disagreed once, and that shipped.

## Update checking

The engine carries the _decision_ half of Blurt's self-update, for the same reason `SetupReadiness` and `UpdateAlertContent` live here: these are rules and wording, and the AppKit shell that applies them has no test target. Nothing here installs anything — it reports whether a newer DMG exists and where to download it, and the user still installs it themselves.

- **`UpdateChecker.check(current:)`** GETs the latest GitHub release of the identity's `releaseURL` repo through the shared `HTTPTransport` seam (so tests substitute `FakeHTTPTransport` instead of the live API) and returns `.upToDate` or `.available(version:dmgURL:)`. It throws on network failure, malformed JSON, an unparseable tag, or a newer release with no DMG asset — the app maps every throw to one "couldn't check" caption.
- **`SemanticVersion`** parses a dotted numeric version with an optional leading `v` (GitHub tags are `v0.1.39`; `CFBundleShortVersionString` is the bare form), comparing component-wise with missing trailing components as zero, so `1.2 == 1.2.0`. A malformed tag reads as "can't determine" rather than crashing.
- **`AutomaticUpdateCheck.shouldRun(isConfigured:lastCheck:now:)`** gates the launch check: never over an unfinished wizard, at most once per `minimumInterval` (24 h, because the unauthenticated GitHub API is rate-limited per IP and five relaunches in an afternoon must not be five fetches), and treating a timestamp in the future — clock correction, a restored backup — as due rather than trusting it. `launchDelay` (3 s) keeps the fetch off the launch path and out of the window before the main `NSWindow` exists to host the result's sheet.
- **`UpdateAlertContent`** owns the wording: title, body, buttons in presentation order, and the URL the _default_ button opens (`nil` when it only dismisses, so "which button downloads" is never re-derived by matching a button title). Its initializer is private, so every alert comes from one of the named results rather than being assembled ad hoc in the shell. `appVersionLabel(_:)` is the one phrasing of the running-version label the alerts and the Settings row share.

## Hotkey building blocks

The engine ships the _decision logic_ for a lone-modifier trigger; the host supplies the event source (in Blurt, a `CGEventTap` — see `App/Blurt/Blurt/Hotkey/DictationKeyTap.swift` for the reference wiring).

- **`TriggerKey`** — the curated lone modifiers usable as a trigger (right ⌘, right ⌥), with keycodes, display labels, and the device-modifier masks the event source needs.
- **`TriggerKeyStore`** — persists the chosen key in `UserDefaults` (`BlurtTriggerKeyCode`), defaulting to right ⌘.
- **`DictationKeyGate`** — a pure, clock-free state machine that turns `modifierDown(at:)` / `modifierUp(at:)` / `otherKeyDown()` into `.start` / `.stop` / `.cancel` / `.none`. Recording starts the instant the modifier goes down; on key-up, a release held ≥ `holdThreshold` (default 1 s) is push-to-talk (stop), a shorter release latches tap-to-toggle (next tap stops). A modifier+key combo from idle cancels the fresh capture; over a latched recording it passes through as a normal shortcut. Callers pass monotonic timestamps, so every decision is deterministic and unit-tested (`DictationKeyGateTests`, `HotkeyRaceTests`).
- **`DictationKeyRouter`** — the recommended layer over the gate: reduce each raw event to `.flagsChanged(keyCode:triggerFlagIsOn:)` / `.keyDown(keyCode:)` and `handle(_:at:)` applies the filters every event source needs — only the bound keycode's flag changes count, and only genuine down/up _edges_ reach the gate (`flagsChanged` deliveries re-report the bit whether or not it changed, so a repeat must not double-start a dictation). `reset()` / `rebind(triggerKeyCode:)` clear state that can no longer be trusted (dropped events, a rebound trigger) and return whether they discarded a live recording. Unit-tested (`DictationKeyRouterTests`).

Map the router's actions onto the session with `submit`: `.start` → `submit(.press)`, `.stop` → `submit(.release)`, `.cancel` → `submit(.cancel)` — event-tap callbacks can't `await`, and `submit` preserves their emit order where per-callback `Task` spawning wouldn't. If your event source can lose key-ups (a disabled tap, a rebind), call the router's `reset()`/`rebind(triggerKeyCode:)` and recover a discarded recording with `submit(.cancelRecording)`.

## Testing your integration

The engine's own tests are the template. They use **Swift Testing** (`@Suite`/`@Test`/`#expect`), not XCTest, and stub all three seams — see `Tests/BlurtEngineTests/Stubs/` (`StubMicCapture`, `StubTranscriber`, `StubInjector`, plus `FakeHTTPTransport` for transport-level transcriber tests):

```swift
let session = DictationSession(
  mic: StubMicCapture(),  // returns a canned buffer above the too-short floor
  transcriber: StubTranscriber(mode: .transcript("hello world")),
  injector: injector,  // records what was "pasted"
  keyTermsProvider: { [] }
)
await session.press()
await session.release()
```

Run `swift test` for the engine suites (`--filter DictationSessionTests` for one suite). `scripts/check.sh` is the full health gate CI runs — tests with warnings-as-errors, a ≥88% engine coverage gate, TSan/ASan passes, and the linters. On a machine without a macOS toolchain, `scripts/check.sh --portable` verifies docs/scripts/site changes only; the Swift side needs a Mac or CI.

## Embedding outside Blurt

The dictation pipeline itself is clean — the three seams, `DictationSession`, the phase projections, and the transcriber carry nothing Blurt-specific. Everything that _was_ Blurt-specific now has a seam: the identity below, and the cue catalog, which the engine no longer ships at all. One thing still doesn't, and it isn't a bug in the engine so much as the shape of a package that has only ever had one host.

### Tell the engine which app it is: `HostIdentity`

Everything the engine writes somewhere addressable is namespaced by one value. Set it once, at your composition root, before you construct any engine type:

```swift
HostIdentity.configure(
  HostIdentity(
    productName: "Acme Voice",                          // update alerts say this
    subsystem: "com.acme.voice",                        // os_log subsystem + queue labels
    keychainService: "acme-voice",                      // the API key's Keychain item
    defaultsPrefix: "AcmeVoice",                        // AcmeVoiceTriggerKeyCode, AcmeVoiceSoundPack, …
    logDirectoryName: "Acme Voice",                     // ~/Library/Logs/Acme Voice/{dictations,errors}.jsonl
    releaseURL: acmeLatestReleaseURL))                  // UpdateChecker's default feed
```

| Field              | What it namespaces                                                              |
| ------------------ | ------------------------------------------------------------------------------- |
| `keychainService`  | `APIKeyStore`'s generic-password item                                           |
| `subsystem`        | every `os_log` category, `OSSignposter`, and the engine's dispatch-queue labels |
| `defaultsPrefix`   | every `DefaultsKey` — the prefix, then the case's raw value                     |
| `logDirectoryName` | `DictationLog.defaultURL` / `defaultErrorURL` under `~/Library/Logs`            |
| `productName`      | `UpdateAlertContent`'s wording, including `appVersionLabel(_:)`                 |
| `releaseURL`       | `UpdateChecker`'s default release feed (still overridable per instance)         |

Doing nothing inherits `HostIdentity.blurt`, which is exactly the set of constants these used to be — so this changed no behaviour for the app in this repo, whose `BlurtApp.init` configures `.blurt` explicitly because the identity is the host's to state. `HostIdentity.current.logger(_:)` is public too, so your own components can log under the same subsystem.

Three things to know. The value is **process-wide**, not injected: its readers are lazily-initialized `static let` loggers, an enum of defaults keys and a Keychain facade, none of which a caller constructs — which is also why the "before you construct any engine type" ordering is a real requirement rather than politeness (a reader that already resolved keeps the identity it resolved with). `defaultsPrefix` is an **on-disk contract** with your shipped users, exactly as a `DefaultsKey` raw value is: changing it later abandons their settings. And `GitHubRelease.dmgAsset` takes the first asset whose name ends in `.dmg`, so it needs nothing from you — but `Update/` is still Blurt's self-update feature living in a dictation engine, which is its own gap below.

### `Update/` isn't part of a dictation engine

`UpdateChecker`, `AutomaticUpdateCheck`, `GitHubRelease`, `UpdateAlertContent`, and `LastUpdateCheckStore` are Blurt's own self-update feature, and they live in the engine for a concrete reason: the AppKit shell has **no unit-test target** (`App/Blurt` builds the app and an XCUITest bundle, nothing else), so a launch gate or an alert's wording written inline there would be covered by nothing. That reasoning is sound for this repo and wrong for a published package — as shipped, the dictation library contains a self-updater for a specific app.

Two ways out, neither taken yet: drop it from the public product (its own target, so it keeps its Swift Testing coverage without riding inside `BlurtEngine`), or finish generalizing it — the repo slug and the product name already come from `HostIdentity`, and `GitHubRelease.dmgAsset` matches any `.dmg`, so what remains is that a dictation library contains a self-updater at all. Note the second is not free — `LastUpdateCheckStore` reads its key from the internal `DefaultsKey` enum, and that enum is deliberately the single roster `PersistedSettings.resetAll` sweeps, so a target split has to keep that invariant intact rather than stranding the update stamp outside the reset (which is exactly the bug the roster was created to prevent, twice).

## Invariants — don't break these

Each was tried the other way and reverted, and they bind engine code as much as the app's. The list is deliberately not repeated here: it lives once, in [AGENTS.md's Settled decisions](../../AGENTS.md#settled-decisions--dont-reintroduce-these) table, alongside the engine conventions those rules rest on (dependency-free by rule; actors own state; the stateless API client stays a `Sendable` struct; new code Swift 6 strict-concurrency clean). `scripts/check-invariants.sh` mechanizes the subset a regex can decide and fails `check.sh` on them, so a good number are enforced rather than remembered — and it pins each rule to the table row it came from, which only works while there is one row to pin to.
