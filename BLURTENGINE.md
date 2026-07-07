# Building on BlurtEngine

BlurtEngine is the Swift package that powers [Blurt](README.md)'s dictation pipeline: capture speech from the microphone, transcribe it in a single AssemblyAI Sync STT call (with server-side cleanup driven by a per-utterance prompt), and paste the polished text into the focused app. This guide is for developers embedding the engine in their own macOS app or extending it inside this repository. For repo-wide conventions and agent workflow, see [AGENTS.md](AGENTS.md).

## What you get

- **`Sources/BlurtEngine/`** — a Swift package (`swift-tools-version:6.2`, macOS 26+, Swift 6 strict concurrency) with **no external dependencies**: just Foundation, Security, AVFoundation, toolchain modules like Synchronization, and AppKit types at the seams. That dependency-free rule is deliberate and enforced — don't add SPM dependencies to the engine.
- Pure logic behind three protocol seams (`MicCaptureProtocol`, `TranscriberProtocol`, `InjectorProtocol`), so every collaborator can be stubbed in tests and replaced in a host app.
- Production implementations of all three seams (`MicCapture`, `AssemblyAITranscriber`, `KeyInjector`), plus the supporting pieces a dictation product needs: Keychain-backed API-key storage, per-utterance contextual prompting, a hotkey state machine, permission checks, and UI-state projections.

What the engine does **not** contain: windows, overlays, menus, or event taps. Those live in the AppKit/SwiftUI shell (`App/Blurt/`), which composes the engine in exactly one place (`AppCoordinator`). If you're building your own host, you play the `AppCoordinator` role.

## Quick start

Add the package (from a checkout or as a local path dependency — the library product is `BlurtEngine`), then compose a session:

```swift
import BlurtEngine

let session = DictationSession(
  mic: MicCapture(),
  transcriber: AssemblyAITranscriber(),
  injector: KeyInjector()
)

// Observe phase changes to drive your UI (single observer — see below).
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

1. **An AssemblyAI API key** saved via `APIKeyStore.set(_:)` (Keychain-backed; users create keys at `APIKeyStore.dashboardURL`) or through an injected `APIKeyGateway` (see below). Without one, transcription fails with `BlurtError.apiKeyMissing` — and if you pass a `readinessCheck` at init (e.g. `{ keyStore.hasKey ? nil : .apiKeyMissing }` over your `APIKeyGateway`), the press is refused _before any capture begins_ instead, so the user never records an utterance that can't be transcribed. Blurt passes exactly that check, and the engine's `OverlayUIState` projection renders the refusal as calm idle (not an error flash) so the host can route straight to its key-entry UI.
2. **Microphone permission** — check and request with `PermissionsChecker`.
3. **Accessibility trust** — required for the paste (`KeyInjector` posts a synthesized ⌘V) and for the focused-field context reads. `PermissionsChecker.check()` reports both; `SetupStatus.isReady` combines permissions + key into a single "ready to dictate" answer.

## The pipeline

```text
press() ──▶ MicCapture.start()            release() ──▶ MicCapture.stop() → Data (raw S16LE PCM)
            (16 kHz mono 16-bit PCM)                    AssemblyAITranscriber.transcribe(pcm:sampleRate:context:)
            + focus/context capture                     (one POST sync.assemblyai.com/transcribe, X-AAI-Model: u3-sync-pro)
            + connection warm-up                        KeyInjector.insert(text, after: priorText)
                                                        (clipboard paste via synthesized ⌘V)
```

Key properties of the design, which your integration can rely on:

- **One request per utterance, no streaming.** The Sync API returns the complete transcript in the response body — no upload step, no job polling, no incremental deltas. `TranscriberProtocol.transcribe` is a single `async throws -> String`. UIs should show a "transcribing…" state and then the whole result; there is nothing to stream.
- **Cleanup happens server-side.** The per-utterance `config.prompt` (built by `TranscriptionPrompt` from the captured context) rides along with the request, so the transcript comes back already polished. There is no separate LLM pass, no styling stage, and deliberately no hook for one — adjust the prompt instead.
- **Latency is pre-paid where possible.** `press()` fires a detached `warmUp()` at the transcriber (pre-opening the HTTPS connection while the user speaks, ~170 ms saved cold) and kicks off the cross-process accessibility read of the focused field without awaiting it — the read is then consumed at transcribe time with a bounded wait (`DictationSession.contextWaitBudget`, 500 ms), so an unresponsive frontmost app costs the transcript its priming, never a multi-second stall — and never delays the recording indicator. On the way out, `release()` flips the phase to `.transcribing` _before_ reading the recorded audio back, so a host's stop cue fires at key-up rather than after the disk read.
- **A held trigger auto-releases.** `DictationSession` stops recording after `maxRecordingSeconds` (default `SyncSTTLimits.autoReleaseSeconds`, 115 s) so audio never exceeds what the Sync endpoint accepts, and transcribes what it has. Clips shorter than `SyncSTTLimits.minPCMBytes` (~100 ms of audio — an accidental tap) are dropped as a silent no-op rather than sent to earn a 400.

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
idle → recording → transcribing → injecting → pasted | noTarget
                          │              │
                          └── failed(BlurtError) / cancelled (from any stage)
```

- `phaseStream()` yields the current phase immediately, then every transition. It is a **single-observer** stream: each call supersedes (finishes) the previous one. That's all a host needs — one renderer — but don't fan it out to multiple long-lived consumers; project the phase into your own state instead.
- `.pasted` and `.noTarget` are terminal _success_ states, not errors. `.noTarget` means transcription worked but nothing editable was focused (or the target app quit), so the text was left on the clipboard — show a quiet "copied" notice, not a failure.
- Two ready-made projections keep UI mapping out of your shell: `phase.overlayState` (`OverlayUIState`: idle / recording / processing / error(message:) / pasted / noTarget, with accessibility labels and — for the transient notices — `noticeDwellSeconds`, how long to hold one before reverting to idle) and `phase.menuBarStatus` (coarser: idle / recording / transcribing, never shows errors, with `symbolName`/`accessibilityLabel` presentation).

### Errors

Failures surface as `PipelinePhase.failed(BlurtError)`:

| Case                                                              | Meaning                                                                                                                                                           |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.apiKeyMissing`                                                  | No AssemblyAI key stored — point the user at your key-entry UI. With a key-presence `readinessCheck`, this surfaces at press time, before any recording.          |
| `.microphonePermissionDenied` / `.accessibilityPermissionMissing` | Permission gaps; `PermissionsChecker` has openers for the right Settings panes.                                                                                   |
| `.audioCaptureFailed(underlying:)`                                | The mic couldn't start, or captured audio couldn't be processed.                                                                                                  |
| `.sttFailed(underlying:)`                                         | The Sync request failed; the underlying error carries the HTTP status and the server's message when available.                                                    |
| `.targetAppLost` / `.noEditableTarget`                            | Paste-side outcomes. When thrown by `KeyInjector` the transcript is already on the clipboard, and the session degrades them to `.noTarget` rather than a failure. |

All cases are `LocalizedError` with user-ready `errorDescription` strings, and `BlurtError` is `Equatable` (wrapped errors compare by NSError domain + code), so phase equality is test-friendly.

## The three seams

`DictationSession`'s collaborators are protocol-typed. Swap any of them to change behavior; keep the contracts below.

### `MicCaptureProtocol` → `MicCapture`

```swift
func start() async throws
func stop() async throws -> Data        // raw S16LE mono PCM, 16 kHz, in order
var levels: AsyncStream<Float> { get }  // 0…1 meter; default: empty stream
func warmUp() async                     // pre-open the device; default: no-op
```

Only `start()`/`stop()` must be implemented — `levels` and `warmUp()` have defaults, so a stub or headless capture conforms for free while hosts still read the meter and warm the device through the same seam they inject.

`MicCapture` records with `AVAudioRecorder` straight to a temp 16 kHz / mono / 16-bit PCM WAV — exactly the geometry the Sync API wants — and reads it back as raw S16LE bytes on `stop()` (no float detour; the blob uploads as-is). A **fresh recorder per session** resolves the current default input device at `record()` time, which is why device switches (headset ↔ built-in) just work. Do **not** replace this with a long-lived `AVAudioEngine`/`installTap` graph: that design was tried, bound itself to one device, and failed with `-10868` or all-zero buffers on device switches.

`MicCapture`'s `levels` is a ~30 Hz meter of the recorder's dBFS power mapped to `0…1` (floored at −50 dBFS so room ambient reads as silence) — feed it to a voice-bars view; it costs nothing when unobserved. Its `warmUp()` pre-creates and prepares a recorder so the first `start()` skips hardware route discovery (Blurt calls it at launch, once mic permission is granted, so warming never triggers the permission prompt).

### `TranscriberProtocol` → `AssemblyAITranscriber`

```swift
func transcribe(pcm: Data, sampleRate: Int, context: TranscriptionContext?) async throws -> String
func warmUp() async   // optional; no-op default
```

`AssemblyAITranscriber` is a stateless `Sendable` struct. One `POST https://sync.assemblyai.com/transcribe` per utterance: the audio as raw S16LE PCM (the `pcm` blob, byte-for-byte) in the `audio` multipart part, plus a JSON `config` part (`sample_rate`, `channels`, and the rendered `prompt`), with `X-AAI-Model: u3-sync-pro` and the API key in `Authorization`. Its initializer takes an `apiKeyProvider` closure (defaults to `APIKeyStore.get`), a `baseURL`, and a `URLSession` — inject a mock session (see `Tests/BlurtEngineTests/Stubs/MockURLProtocol.swift`) to test against canned responses. `warmUp()` fires a throwaway GET at the host root to pre-pool the connection; it never throws and any failure just means the real request pays connection setup as before.

The model's limits live in `SyncSTTLimits` (16 kHz sample rate, ~0.1 s–120 s audio, and the auto-release math) — the single source shared by the mic, the session, and the request so recorded and declared geometry can't drift.

### `InjectorProtocol` → `KeyInjector`

```swift
func setTargetApp(_ app: NSRunningApplication?) async
func insert(_ text: String, after priorText: String?, windowTitle: String?) async throws
```

`KeyInjector.insert` **always** pastes: it saves the current pasteboard, writes the transcript, activates the captured target app, posts a synthesized ⌘V, waits for the target to read the clipboard (`pasteSettleDuration`, default 400 ms, tunable in the initializer), then restores the prior pasteboard contents. There is no keystroke-by-keystroke typing path and no length threshold. If the target app is gone or nothing editable is focused it leaves the text on the clipboard and throws `.targetAppLost` / `.noEditableTarget` — which the session turns into the quiet `.noTarget` outcome. `priorText` (the text before the caret, captured at press time) drives `withLeadingSeparator`, which joins consecutive dictations with a space so they don't run together. When `priorText` is unreadable (an Accessibility-opaque editor, or a browser tab like Google Docs whose canvas-rendered body exposes no AX text), `separatorBasis` falls back to what was last pasted — but only when both the target app **and** `windowTitle` match the last successful insert, so the fallback tracks "the same window," not just "the same process" (a browser hosts many unrelated tabs/documents under one PID).

The session calls `setTargetApp` at press time with the app that was frontmost when recording started — so the paste lands where the user was, even if focus moved during transcription.

## Context and prompting

Recognition quality comes from per-utterance priming, assembled automatically inside `press()` — hosts don't call these APIs directly, but should know what's collected:

- **`TranscriptionContext`** carries the frontmost app name, window title, focused-field label, the text before the caret, the selected text (which a paste will replace), and the user's key terms. It's captured via Accessibility at press time (skipped in secure fields), off the hot path — and consumed at transcribe time with a bounded wait (`DictationSession.contextWaitBudget`), so a hung read is abandoned rather than stalling the transcript.
- **`TranscriptionPrompt.build(context:)`** renders that into the Sync request's `config.prompt`, opening with the fixed `baseInstruction` ("Transcribe without speaker labels, audio event descriptions, or emotion markers.") and staying under the API's 4096-character cap. An empty context yields `nil`, which omits the field so the server applies its own default. Two deliberate omissions, both regression-tested: no language directive (pinning to English hurt non-English speech) and no "remove filler words" clause (not in the model's trained instruction set — a no-op). Don't reintroduce either.
- **`KeyTermsStore`** persists the user's domain vocabulary (names, jargon) in `UserDefaults`; `DictationSession` re-reads it at every press via its `keyTermsProvider` closure, so Settings edits apply to the next utterance without rebuilding the session. Pass your own provider to source terms from elsewhere.

For key storage, compose against **`APIKeyGateway`** — the injectable get/set/`hasKey` seam over the key store. `ProductionAPIKeyStore` forwards to the Keychain-backed `APIKeyStore`; `InMemoryAPIKeyStore` is a ready-made in-memory conformance for tests and harnesses (Blurt's XCUITest runs use it so the real Keychain item is never touched, and its `hasKey` backs the session's `readinessCheck`). For a settings UI, **`APIKeySubmission`** wraps the gateway with the validate-then-save flow (`submit(_:)` → valid / invalid / unreachable / saveFailed, via `APIKeyValidator`): it saves only a key AssemblyAI actively accepts, so an unverified key never persists.

Each completed dictation is appended to **`DictationLog`** (a local JSONL history at `~/Library/Logs/Blurt/dictations.jsonl`, the path `DictationLog.defaultURL` exposes) with its context snapshot — but only while developer mode is switched on. **`DeveloperModeStore`** persists that opt-in in `UserDefaults` (`BlurtDeveloperMode`, off by default); with it off, nothing is written to disk. Blurt surfaces the switch (and the log path) in the Settings window's Developer section.

## Hotkey building blocks

The engine ships the _decision logic_ for a lone-modifier trigger; the host supplies the event source (in Blurt, a `CGEventTap` — see `App/Blurt/Blurt/Hotkey/DictationKeyTap.swift` for the reference wiring).

- **`TriggerKey`** — the curated lone modifiers usable as a trigger (right ⌘, right ⌥, right ⌃, `fn`), with keycodes, display labels, and the device-modifier masks the event source needs.
- **`TriggerKeyStore`** — persists the chosen key in `UserDefaults` (`BlurtTriggerKeyCode`), defaulting to right ⌘.
- **`DictationKeyGate`** — a pure, clock-free state machine that turns `modifierDown(at:)` / `modifierUp(at:)` / `otherKeyDown()` into `.start` / `.stop` / `.cancel` / `.none`. Recording starts the instant the modifier goes down; on key-up, a release held ≥ `holdThreshold` (default 1 s) is push-to-talk (stop), a shorter release latches tap-to-toggle (next tap stops). A modifier+key combo from idle cancels the fresh capture; over a latched recording it passes through as a normal shortcut. Callers pass monotonic timestamps, so every decision is deterministic and unit-tested (`DictationKeyGateTests`, `HotkeyRaceTests`).
- **`DictationKeyRouter`** — the recommended layer over the gate: reduce each raw event to `.flagsChanged(keyCode:triggerFlagIsOn:)` / `.keyDown(keyCode:)` and `handle(_:at:)` applies the filters every event source needs — only the bound keycode's flag changes count, and only genuine down/up _edges_ reach the gate (`flagsChanged` deliveries re-report the bit whether or not it changed, so a repeat must not double-start a dictation). `reset()` / `rebind(triggerKeyCode:)` clear state that can no longer be trusted (dropped events, a rebound trigger) and return whether they discarded a live recording. Unit-tested (`DictationKeyRouterTests`).

Map the router's actions onto the session with `submit`: `.start` → `submit(.press)`, `.stop` → `submit(.release)`, `.cancel` → `submit(.cancel)` — event-tap callbacks can't `await`, and `submit` preserves their emit order where per-callback `Task` spawning wouldn't. If your event source can lose key-ups (a disabled tap, a rebind), call the router's `reset()`/`rebind(triggerKeyCode:)` and recover a discarded recording with `submit(.cancelRecording)`.

## Testing your integration

The engine's own tests are the template. They use **Swift Testing** (`@Suite`/`@Test`/`#expect`), not XCTest, and stub all three seams — see `Tests/BlurtEngineTests/Stubs/` (`StubMicCapture`, `StubTranscriber`, `StubInjector`, plus `MockURLProtocol` for transport-level transcriber tests):

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

Run `swift test` for the engine suites (`--filter DictationSessionTests` for one suite). `scripts/check.sh` is the full health gate CI runs — tests with warnings-as-errors, a ≥80% engine coverage gate, TSan/ASan passes, and the linters. On a machine without a macOS toolchain, `scripts/check.sh --portable` verifies docs/scripts/site changes only; the Swift side needs a Mac or CI.

## Invariants — don't break these

Each of these was tried the other way and reverted; the longer stories are in [AGENTS.md](AGENTS.md) and the source comments:

- **No external SPM dependencies in the engine.** Foundation/Security/AVFoundation only.
- **No streaming STT, no local models, no separate LLM cleanup pass.** One Sync request per utterance is the architecture; cleanup belongs in `TranscriptionPrompt`.
- **No `AVAudioEngine`/`installTap` capture path.** Fresh `AVAudioRecorder` per session, resolved at record time.
- **Paste is always clipboard-based** (save → write → ⌘V → settle → restore), with the copied-to-clipboard degradation for lost targets.
- **No English-pinning or filler-word clauses in the prompt.**
- **Actors own state** (`DictationSession`, `KeyInjector`, `MicCapture`); the stateless API client stays a `Sendable` struct. Keep new code Swift 6 strict-concurrency clean.
