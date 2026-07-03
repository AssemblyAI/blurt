# Prompt Inspector — design

## Goal

Ship an undocumented global hotkey in the release build of Blurt that opens a
window displaying the **fully-assembled prompt from the most recent dictation**
— the exact `config.prompt` string sent to AssemblyAI's Sync STT API.

This is a debugging aid for understanding what priming context (prior text,
selected text, app/window/field location clause, keywords) Blurt actually put on
the wire. It is present in the notarized release but undocumented — reachable
only by those who know the chord.

## Constraints & decisions

- **Ships in release** — no `#if DEBUG` / `#if UITEST_HOOKS` gating on the
  feature itself. It must work in the notarized build.
- **Last-sent, fully-assembled prompt** — the return value of
  `TranscriptionPrompt.build(context:)`, captured at attempt time (before the
  network call), so a failed request still shows what it tried to send.
- **In-memory only** — the prompt can contain the user's prior transcript and
  on-screen selected text. Only the single most-recent prompt is held, in
  memory, never written to disk.
- **No new permissions, no new event tap** — reuse the existing system-wide
  listen-only `CGEventTap` in `DictationKeyTap`, which already requires only
  Accessibility (Blurt has it) and already observes every `keyDown`.
- **Hotkey = ⌃⌥⌘P** (control+option+command+P, virtual keycode 35). Mnemonic
  "Prompt", vanishingly rare, and cannot collide with the lone-modifier
  dictation trigger. This is a key+modifier chord, but it is a *separate
  undocumented feature*, not a change to the dictation trigger (which remains a
  single lone modifier per project guardrails). No `KeyboardShortcuts` package —
  detection lives in the existing tap.
- **Opens/focuses** the window (close with ⌘W); repeat press re-focuses rather
  than toggling closed.

## Components & data flow

```
AssemblyAITranscriber.transcribe(...)
  → TranscriptionPrompt.build(context:)         [full prompt string in memory]
  → onPromptAssembled?(prompt)                  [new optional closure, engine]
      ↓ (hop to MainActor)
  PromptInspector.shared.record(prompt)         [app, @Observable singleton]
      ↓ (SwiftUI observation)
  Prompt Inspector Window                        [app, suppressed-by-default scene]

DictationKeyTap.decideAction(keyDown ⌃⌥⌘P)
  → onInspector()                                [new callback]
  → AppCoordinator (pass-through)
  → AppDelegate.openWindowByID(inspector id)     [opens/focuses the window]
```

### 1. Engine — capture (`Sources/BlurtEngine/STT/AssemblyAITranscriber.swift`)

- Add a stored optional closure to `AssemblyAITranscriber`:
  ```swift
  let onPromptAssembled: (@Sendable (String?) -> Void)?  // default nil
  ```
  Added to the initializer with a default of `nil` so existing call sites and
  tests are unaffected and the engine stays decoupled from the UI.
- In `transcribe(samples:sampleRate:context:)`, immediately after building the
  prompt (`let prompt = TranscriptionPrompt.build(context: context)`, ~line 52)
  and before encoding/sending, call `onPromptAssembled?(prompt)`.
- The engine never references any window or app type. `nil` = no-op.

### 2. App — hold (`App/Blurt/Blurt/` new file, e.g. `PromptInspector/PromptInspector.swift`)

- `@MainActor @Observable final class PromptInspector` with:
  - `static let shared = PromptInspector()`
  - `private(set) var lastPrompt: String?`
  - `private(set) var lastSentAt: Date?`
  - `func record(_ prompt: String?)` — sets both fields (timestamp always
    updates on a recorded attempt, even when `prompt` is `nil`, i.e. no context
    produced a prompt).
- Wired in `App/Blurt/Blurt/DictationComposition.swift` `production()`:
  ```swift
  AssemblyAITranscriber(onPromptAssembled: { prompt in
    Task { @MainActor in PromptInspector.shared.record(prompt) }
  })
  ```

### 3. App — show (`App/Blurt/Blurt/App.swift` + a view file)

- New scene in `BlurtApp.body`:
  ```swift
  Window("Prompt Inspector", id: PromptInspectorWindow.id) {
    PromptInspectorView()
  }
  .defaultLaunchBehavior(.suppressed)
  ```
  (`PromptInspectorWindow.id` a small `enum` mirroring `MainWindow.id`.)
- `PromptInspectorView` renders `PromptInspector.shared`:
  - Selectable, monospaced, scrollable text of `lastPrompt`.
  - `lastSentAt` timestamp (relative or absolute).
  - Empty state: "No prompt captured yet — dictate once, then reopen."
  - **Copy** button (copies `lastPrompt` to the pasteboard).

### 4. App — open (hotkey) (`App/Blurt/Blurt/Hotkey/DictationKeyTap.swift`)

- Add constructor parameter `onInspector: @escaping @Sendable () -> Void`.
- In `decideAction`, on `.keyDown` where `keyCode == 35` and `eventFlags`
  contains all of `.maskControl`, `.maskAlternate`, `.maskCommand`, fire
  `onInspector()` (return `.none` from the gate — the chord is not a dictation
  event). Keep the tap listen-only; the chord also passes through to the
  frontmost app (harmless).
- `AppCoordinator` (`App/Blurt/Blurt/AppCoordinator.swift`) passes the callback
  through when constructing `DictationKeyTap`.
- `AppDelegate` (`App/Blurt/Blurt/AppDelegate.swift`) supplies the callback,
  which calls its existing `openWindowByID` with the inspector window id and
  activates the app so the window comes forward.

### 5. Error handling

- No network or file I/O is added, so no new failure modes. If `onPromptAssembled`
  is unset (engine used standalone), nothing records — the window shows its empty
  state. Recording `nil` (no context → no prompt) is a valid state the view
  distinguishes from "never dictated".

## Testing (Swift Testing, per project convention)

- `PromptInspector.record(_:)` sets `lastPrompt` and `lastSentAt`; recording
  `nil` still updates `lastSentAt`.
- `DictationKeyTap` fires `onInspector` on the ⌃⌥⌘P chord and does **not** fire
  it on other keydowns or on the dictation trigger — exercised via a
  `#if UITEST_HOOKS` simulate seam paralleling the existing
  `simulatePressForTesting()`.
- Engine wiring: prompt assembly is already covered at the pure
  `TranscriptionPrompt.build(context:)` boundary; add a focused check that
  `AssemblyAITranscriber` invokes `onPromptAssembled` with the built prompt where
  feasible without a live network call.

## Build

- New Swift files are picked up by the `project.yml` source globs → run
  `xcodegen generate` after adding them. **Do not** hand-edit
  `project.pbxproj` (generated; a hook blocks it).
- No changes to build configurations or compilation conditions — the feature
  ships in all configs including Release.

## Out of scope (YAGNI)

- Showing the context breakdown (app/window/field/keywords) separately — only
  the assembled string is shown.
- History of more than the single most-recent prompt.
- Toggling the window closed on repeat hotkey press.
- Persisting prompts to disk or logs.
