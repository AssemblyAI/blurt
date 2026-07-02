# Prompt Inspector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an undocumented global hotkey (⌃⌥⌘P) in Blurt's release build that opens a window showing the fully-assembled prompt from the most recent dictation.

**Architecture:** The engine captures the assembled prompt string at the point it is built inside `AssemblyAITranscriber` and hands it to an injected closure. The app wires that closure to a `@MainActor @Observable` singleton (`PromptInspector`) that a suppressed-by-default SwiftUI `Window` renders. The chord is detected inside the existing system-wide `CGEventTap` (`DictationKeyTap`) via a pure engine matcher (`InspectorHotkey`), and firing it opens the window through `AppDelegate`. No new event tap, no new permissions.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, Swift Testing, XcodeGen, BlurtEngine SPM package.

## Global Constraints

- Ships in **all** configurations including Release — no `#if DEBUG` / `#if UITEST_HOOKS` gating on the feature. (Spec: "Ships in release".)
- Prompt is held **in memory only** — never written to disk or logs. (Spec: privacy.)
- No new SPM dependency in `Sources/BlurtEngine/` — Foundation/Security/AVFoundation/CoreGraphics-system only. (project-guardrails.)
- The engine stays free of CoreGraphics `CGEvent*` types — the tap translates events to primitive values before calling engine code (mirrors `DictationKeyGate`). (Existing pattern.)
- **Never** hand-edit `App/Blurt/Blurt.xcodeproj/project.pbxproj` — it is generated from `project.yml`; run `xcodegen generate` after adding files. A PreToolUse hook blocks direct edits and `check.sh` fails on drift. (project-guardrails.)
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), not XCTest. The App layer has **no unit-test target** — put all unit tests in `Tests/BlurtEngineTests/`; app-layer glue is verified by build + the manual smoke test in Task 5. (Repo layout.)
- Hotkey chord = **⌃⌥⌘P**: virtual keycode `35` (P) + the generic control/option/command CGEventFlags bits (`0x40000 | 0x80000 | 0x100000` = `0x1C0000`). Extra modifiers (shift, fn) still match. This is a separate undocumented feature, not a change to the lone-modifier dictation trigger. (Spec.)

---

### Task 1: Engine — capture the assembled prompt (`onPromptAssembled` hook)

**Files:**
- Modify: `Sources/BlurtEngine/STT/AssemblyAITranscriber.swift` (init at 33–41, `transcribe` at 45–69)
- Test: `Tests/BlurtEngineTests/AssemblyAITranscriberTests.swift`

**Interfaces:**
- Produces: `AssemblyAITranscriber.init(..., onPromptAssembled: (@Sendable (String?) -> Void)? = nil)` — the closure receives the exact prompt string (or `nil` when no context produced one) just before the request is sent. Default `nil` = no-op.

- [ ] **Step 1: Write the failing test**

Add to `Tests/BlurtEngineTests/AssemblyAITranscriberTests.swift` inside the `HTTPClientTests` suite (uses the existing `mockURLSession()` / `json(...)` helpers and `Counter` / `MockURLProtocol` already imported by the file):

```swift
  @Test("transcribe hands the assembled prompt to onPromptAssembled before sending")
  func transcribeReportsAssembledPrompt() async throws {
    MockURLProtocol.responder = { request in
      guard request.url?.path.hasSuffix("/transcribe") == true else { return (404, Data()) }
      return (200, json(["text": "ok"]))
    }
    defer { MockURLProtocol.responder = nil }

    let captured = Box<String?>(nil)
    let seen = Counter()
    let transcriber = AssemblyAITranscriber(
      apiKeyProvider: { "test-key" },
      baseURL: URL(string: "https://sync.assemblyai.com")!,
      urlSession: mockURLSession(),
      onPromptAssembled: { prompt in _ = seen.next(); captured.value = prompt }
    )

    // A real context builds a non-nil prompt that echoes the prior text.
    _ = try await transcriber.transcribe(
      samples: [0, 0.1, -0.1],
      sampleRate: 16_000,
      context: TranscriptionContext(appName: "Slack", priorText: "Dear Sam,"))
    #expect(seen.value == 1)
    #expect(captured.value?.contains("Dear Sam,") == true)

    // A nil context builds no prompt: the closure still fires, with nil.
    captured.value = "unset"
    _ = try await transcriber.transcribe(samples: [0, 0.1, -0.1], sampleRate: 16_000, context: nil)
    #expect(seen.value == 2)
    #expect(captured.value == nil)
  }
```

Add this small thread-safe box near the bottom of the file (after the `makeTranscriber`/`collectTranscript` helpers, before the closing brace) so the `@Sendable` closure can write across the await without a data-race warning:

```swift
  /// Minimal Sendable mutable cell for capturing a value out of a @Sendable
  /// callback in a test. Serialized by a lock; the test reads it after the awaited
  /// call returns, so contention is nil in practice.
  private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ initial: T) { stored = initial }
    var value: T {
      get { lock.withLock { stored } }
      set { lock.withLock { stored = newValue } }
    }
  }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter transcribeReportsAssembledPrompt`
Expected: FAIL — `AssemblyAITranscriber` has no `onPromptAssembled` parameter (compile error).

- [ ] **Step 3: Write minimal implementation**

In `Sources/BlurtEngine/STT/AssemblyAITranscriber.swift`, add the stored property beside the other lets (after line 21):

```swift
  private let onPromptAssembled: (@Sendable (String?) -> Void)?
```

Extend the initializer (lines 33–41) to accept and store it:

```swift
  public init(
    apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.get() },
    baseURL: URL = URL(string: "https://sync.assemblyai.com")!,
    urlSession: URLSession = .shared,
    onPromptAssembled: (@Sendable (String?) -> Void)? = nil
  ) {
    self.apiKeyProvider = apiKeyProvider
    self.baseURL = baseURL
    self.urlSession = urlSession
    self.onPromptAssembled = onPromptAssembled
  }
```

In `transcribe(...)`, replace the single inlined build call (line 52):

```swift
    let config = try makeConfigData(sampleRate: sampleRate, prompt: TranscriptionPrompt.build(context: context))
```

with a captured local that is reported before the request is built and sent:

```swift
    let prompt = TranscriptionPrompt.build(context: context)
    // Report the fully-assembled prompt (or nil when no context produced one)
    // before sending, so a failed request still surfaces what it tried to send.
    onPromptAssembled?(prompt)
    let config = try makeConfigData(sampleRate: sampleRate, prompt: prompt)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter transcribeReportsAssembledPrompt`
Expected: PASS. Then run the whole transcriber suite to confirm no regression: `swift test --filter HTTPClientTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BlurtEngine/STT/AssemblyAITranscriber.swift Tests/BlurtEngineTests/AssemblyAITranscriberTests.swift
git commit -m "feat(engine): report assembled prompt via onPromptAssembled hook

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Engine — inspector chord matcher (`InspectorHotkey`)

**Files:**
- Create: `Sources/BlurtEngine/Hotkey/InspectorHotkey.swift`
- Test: `Tests/BlurtEngineTests/InspectorHotkeyTests.swift`

**Interfaces:**
- Produces: `InspectorHotkey.matches(keyCode: Int, flags: UInt64) -> Bool` — true iff `keyCode == 35` and all three of the control/option/command generic flag bits are set. `flags` is a raw `CGEventFlags` value passed as `UInt64` so the engine stays CoreGraphics-free.

- [ ] **Step 1: Write the failing test**

Create `Tests/BlurtEngineTests/InspectorHotkeyTests.swift`:

```swift
import Testing

@testable import BlurtEngine

@Suite("InspectorHotkey chord matching")
struct InspectorHotkeyTests {
  // Generic CGEventFlags bits: control 0x40000, option 0x80000, command 0x100000.
  private let ctrlOptCmd: UInt64 = 0x40000 | 0x80000 | 0x100000
  private let pKey = 35

  @Test("matches control+option+command+P")
  func matchesChord() {
    #expect(InspectorHotkey.matches(keyCode: pKey, flags: ctrlOptCmd))
  }

  @Test("matches even with extra modifiers held (shift, fn)")
  func matchesWithExtraModifiers() {
    let withShiftAndFn = ctrlOptCmd | 0x20000 | 0x800000
    #expect(InspectorHotkey.matches(keyCode: pKey, flags: withShiftAndFn))
  }

  @Test("does not match the wrong key")
  func rejectsWrongKey() {
    #expect(!InspectorHotkey.matches(keyCode: 8 /* C */, flags: ctrlOptCmd))
  }

  @Test("does not match when a required modifier is missing")
  func rejectsMissingModifier() {
    #expect(!InspectorHotkey.matches(keyCode: pKey, flags: 0x80000 | 0x100000)) // no control
    #expect(!InspectorHotkey.matches(keyCode: pKey, flags: 0x40000 | 0x100000)) // no option
    #expect(!InspectorHotkey.matches(keyCode: pKey, flags: 0x40000 | 0x80000))  // no command
  }

  @Test("does not match a bare P keypress")
  func rejectsBareKey() {
    #expect(!InspectorHotkey.matches(keyCode: pKey, flags: 0))
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter InspectorHotkeyTests`
Expected: FAIL — `InspectorHotkey` is not defined (compile error).

- [ ] **Step 3: Write minimal implementation**

Create `Sources/BlurtEngine/Hotkey/InspectorHotkey.swift`:

```swift
/// The undocumented Prompt Inspector chord: ⌃⌥⌘P.
///
/// A pure matcher kept in the engine (CoreGraphics-free, so unit-testable) that
/// `DictationKeyTap` calls with primitive values pulled off a `CGEvent`. Mirrors
/// how `DictationKeyGate` owns the per-event decision while the tap only bridges.
///
/// The flag bits are the *generic* CGEventFlags masks (side-agnostic), so the
/// chord fires regardless of which control/option/command key is held. Extra
/// modifiers (shift, fn) don't block the match — this is a debug affordance, not
/// a user-facing shortcut that must be exact.
public enum InspectorHotkey {
  /// Virtual key code for the "P" key (mnemonic: Prompt).
  public static let keyCode = 35

  /// control | option | command (generic CGEventFlags mask bits).
  static let requiredFlags: UInt64 = 0x40000 | 0x80000 | 0x100000

  /// Whether a key-down of `keyCode` with `flags` set is the inspector chord.
  public static func matches(keyCode: Int, flags: UInt64) -> Bool {
    keyCode == Self.keyCode && (flags & requiredFlags) == requiredFlags
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter InspectorHotkeyTests`
Expected: PASS (all five cases).

- [ ] **Step 5: Commit**

```bash
git add Sources/BlurtEngine/Hotkey/InspectorHotkey.swift Tests/BlurtEngineTests/InspectorHotkeyTests.swift
git commit -m "feat(engine): add InspectorHotkey chord matcher

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: App — PromptInspector store, view, and window scene

**Files:**
- Create: `App/Blurt/Blurt/PromptInspector/PromptInspector.swift`
- Create: `App/Blurt/Blurt/PromptInspector/PromptInspectorView.swift`
- Modify: `App/Blurt/Blurt/App.swift` (add scene to `BlurtApp.body`)

**Interfaces:**
- Produces: `PromptInspector.shared` (`@MainActor @Observable`) with `private(set) var lastPrompt: String?`, `private(set) var lastSentAt: Date?`, and `func record(_ prompt: String?)`.
- Produces: `PromptInspectorWindow.id` (`String`) — scene id for `openWindow(id:)`.
- Consumes: nothing from earlier tasks yet (wired in Task 4).

Note: the App layer has no unit-test target, so this task's gate is "the app compiles and the scene is present." Behavior is exercised by the Task 5 smoke test.

- [ ] **Step 1: Create the store**

Create `App/Blurt/Blurt/PromptInspector/PromptInspector.swift`:

```swift
import Foundation
import Observation

/// Holds the fully-assembled prompt from the most recent dictation for the
/// undocumented Prompt Inspector window (opened with ⌃⌥⌘P). In-memory only — the
/// prompt can contain the user's prior transcript and on-screen selected text, so
/// it is never written to disk. Only the single most-recent prompt is retained.
@MainActor
@Observable
final class PromptInspector {
  static let shared = PromptInspector()
  private init() {}

  private(set) var lastPrompt: String?
  private(set) var lastSentAt: Date?

  /// Records the prompt from the latest dictation attempt. `nil` means the
  /// dictation produced no context prompt; `lastSentAt` still updates so the view
  /// can tell "no prompt this time" from "never dictated".
  func record(_ prompt: String?) {
    lastPrompt = prompt
    lastSentAt = Date()
  }
}
```

- [ ] **Step 2: Create the view + scene id**

Create `App/Blurt/Blurt/PromptInspector/PromptInspectorView.swift`:

```swift
import AppKit
import SwiftUI

/// Scene identifier for the undocumented Prompt Inspector `Window` scene.
enum PromptInspectorWindow {
  static let id = "prompt-inspector"
}

/// Read-only view of the most recent assembled prompt. Opened via ⌃⌥⌘P; closed
/// with ⌘W. Selectable + copyable so the text can be pasted elsewhere.
struct PromptInspectorView: View {
  @State private var inspector = PromptInspector.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Prompt Inspector").font(.headline)
        Spacer()
        if let sentAt = inspector.lastSentAt {
          Text(sentAt, style: .time)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Button("Copy", action: copy)
          .disabled(inspector.lastPrompt == nil)
      }
      Divider()
      content
    }
    .padding(16)
    .frame(minWidth: 440, minHeight: 320)
  }

  @ViewBuilder private var content: some View {
    if let prompt = inspector.lastPrompt {
      ScrollView {
        Text(prompt)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else {
      Text(
        inspector.lastSentAt == nil
          ? "No prompt captured yet — dictate once, then reopen."
          : "Last dictation sent no prompt (no context available)."
      )
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func copy() {
    guard let prompt = inspector.lastPrompt else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(prompt, forType: .string)
  }
}
```

- [ ] **Step 3: Add the scene to the app**

In `App/Blurt/Blurt/App.swift`, add this scene inside `BlurtApp.body` immediately after the `MenuBarExtra { … }` block (line 49) and before the `#if UITEST_HOOKS` block (line 51):

```swift
    // Undocumented Prompt Inspector: shows the fully-assembled prompt sent to
    // AssemblyAI on the last dictation. Never appears on its own (.suppressed);
    // opened by the ⌃⌥⌘P chord (see DictationKeyTap / AppDelegate). Ships in all
    // configurations — it is intentionally present but undocumented.
    Window("Prompt Inspector", id: PromptInspectorWindow.id) {
      PromptInspectorView()
    }
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(.suppressed)
```

- [ ] **Step 4: Regenerate the project and build**

Run:
```bash
cd App/Blurt && xcodegen generate --quiet && cd ../..
xcodebuild -project App/Blurt/Blurt.xcodeproj -scheme Blurt -configuration Debug-Local -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/blurt-plan-build build CODE_SIGNING_ALLOWED=NO | xcbeautify --quiet
```
Expected: BUILD SUCCEEDED, and `git status` shows `App/Blurt/Blurt.xcodeproj/project.pbxproj` updated to include the two new files.

- [ ] **Step 5: Commit**

```bash
git add App/Blurt/Blurt/PromptInspector/ App/Blurt/Blurt/App.swift App/Blurt/Blurt.xcodeproj/project.pbxproj
git commit -m "feat(app): add Prompt Inspector window and store

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: App — wire capture and the ⌃⌥⌘P open path

**Files:**
- Modify: `App/Blurt/Blurt/DictationComposition.swift` (`production()`, lines 18–24)
- Modify: `App/Blurt/Blurt/Hotkey/DictationKeyTap.swift` (init 57–67; `handle` 142–161)
- Modify: `App/Blurt/Blurt/AppCoordinator.swift` (init 44–63; `startDictationDriver` 97–113)
- Modify: `App/Blurt/Blurt/AppDelegate.swift` (add method; `applicationDidFinishLaunching` coordinator construction, lines 109–137)

**Interfaces:**
- Consumes: `AssemblyAITranscriber(onPromptAssembled:)` (Task 1), `PromptInspector.shared.record(_:)` and `PromptInspectorWindow.id` (Task 3), `InspectorHotkey.matches(keyCode:flags:)` (Task 2).
- Produces: `DictationKeyTap.init(..., onInspector: @escaping @MainActor () -> Void)`; `AppCoordinator.init(..., onInspector: @escaping @MainActor () -> Void = {})`; `AppDelegate.openInspectorWindow()`.

No unit test (app layer). Gate is a clean build; end-to-end behavior is Task 5.

- [ ] **Step 1: Wire the capture closure in production composition**

In `App/Blurt/Blurt/DictationComposition.swift`, replace the `transcriber:` line in `production()` (line 21):

```swift
      transcriber: AssemblyAITranscriber(),
```

with:

```swift
      transcriber: AssemblyAITranscriber(
        onPromptAssembled: { prompt in
          // Hop to the main actor: PromptInspector is @MainActor UI state.
          Task { @MainActor in PromptInspector.shared.record(prompt) }
        }
      ),
```

- [ ] **Step 2: Detect the chord in the key tap**

In `App/Blurt/Blurt/Hotkey/DictationKeyTap.swift`:

Add a stored callback beside the others (after line 39, the `onRecordingDiscarded` property):

```swift
  /// Fired when the undocumented Prompt Inspector chord (⌃⌥⌘P) is pressed. Opens
  /// the inspector window; the tap is listen-only so the chord also passes through
  /// to the focused app (harmless). See `InspectorHotkey`.
  private let onInspector: @MainActor () -> Void
```

Add the parameter to `init` (lines 57–67) — insert after `onRecordingDiscarded:` in both the signature and the assignments:

```swift
  init(
    onStart: @escaping @Sendable () -> Void,
    onStop: @escaping @Sendable () -> Void,
    onCancel: @escaping @Sendable () -> Void,
    onRecordingDiscarded: @escaping @Sendable () -> Void,
    onInspector: @escaping @MainActor () -> Void
  ) {
    self.onStart = onStart
    self.onStop = onStop
    self.onCancel = onCancel
    self.onRecordingDiscarded = onRecordingDiscarded
    self.onInspector = onInspector
  }
```

In `handle(type:event:)`, after `let eventFlags = event.flags` (line 158) and before `let now = …` (line 159), add:

```swift
    // Undocumented Prompt Inspector chord. Checked here (not in the gate) so the
    // gate's dictation decision is untouched — the event still flows through it
    // normally below. Listen-only tap swallows nothing, so this never blocks the
    // keystroke reaching the focused app.
    if type == .keyDown, InspectorHotkey.matches(keyCode: keyCode, flags: eventFlags.rawValue) {
      onInspector()
    }
```

- [ ] **Step 3: Thread the callback through the coordinator**

In `App/Blurt/Blurt/AppCoordinator.swift`:

Add a stored property after `onMissingAPIKey` (line 15):

```swift
  /// Opens the undocumented Prompt Inspector window. Supplied by the app shell;
  /// fired by the key tap on the ⌃⌥⌘P chord.
  let onInspector: @MainActor () -> Void
```

Add the parameter to `init` (lines 44–49) and assign it (after line 50):

```swift
  init(
    onMissingAPIKey: @escaping @MainActor () -> Void,
    components: DictationComponents = .production(),
    keyStore: any APIKeyGateway = ProductionAPIKeyStore(),
    isUITesting: Bool = false,
    onInspector: @escaping @MainActor () -> Void = {}
  ) {
    self.onMissingAPIKey = onMissingAPIKey
    self.onInspector = onInspector
```

(Leave the remaining assignments in `init` unchanged.)

In `startDictationDriver()` (lines 99–105), add the argument to the `DictationKeyTap(...)` call — insert after the `onRecordingDiscarded:` line:

```swift
    keyTap = DictationKeyTap(
      onStart: { session.submit(.press) },
      onStop: { session.submit(.release) },
      onCancel: { session.submit(.cancel) },
      onRecordingDiscarded: { session.submit(.cancelRecording) },
      onInspector: onInspector
    )
```

- [ ] **Step 4: Open the window from the app delegate**

In `App/Blurt/Blurt/AppDelegate.swift`, add this method after `openMainWindow()` (line 31):

```swift
  /// Opens the undocumented Prompt Inspector window and brings Blurt frontmost
  /// (the user is typically in another app when they press ⌃⌥⌘P). The window is
  /// `.suppressed` at launch, so `openWindow(id:)` creates it on first use and
  /// focuses it thereafter. `openWindowByID` is captured by the main window's
  /// launch-time `onAppear`, so it is set well before any chord can fire.
  @MainActor func openInspectorWindow() {
    NSApp.activate()
    openWindowByID?(PromptInspectorWindow.id)
  }
```

Pass the callback into each `AppCoordinator(...)` construction in `applicationDidFinishLaunching` (lines 127–136). Define it once alongside `onMissingAPIKey` (after line 109):

```swift
    let onInspector: @MainActor () -> Void = { [weak self] in self?.openInspectorWindow() }
```

Then add `onInspector: onInspector` to every `AppCoordinator(...)` call in the method. There are three:

- the UITEST `.uiTest()` construction (lines 127–131) — add `onInspector: onInspector,` before `components:`,
- the UITEST non-active fallback (line 133) — `AppCoordinator(onMissingAPIKey: onMissingAPIKey, onInspector: onInspector)`,
- the `#else` production construction (line 136) — `AppCoordinator(onMissingAPIKey: onMissingAPIKey, onInspector: onInspector)`.

- [ ] **Step 5: Build and verify concurrency is clean**

Run:
```bash
xcodebuild -project App/Blurt/Blurt.xcodeproj -scheme Blurt -configuration Debug-Local -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/blurt-plan-build build CODE_SIGNING_ALLOWED=NO | xcbeautify --quiet
```
Expected: BUILD SUCCEEDED with no Swift-6 concurrency warnings (the target treats warnings as errors, so any `@Sendable`/actor issue fails the build here).

- [ ] **Step 6: Commit**

```bash
git add App/Blurt/Blurt/DictationComposition.swift App/Blurt/Blurt/Hotkey/DictationKeyTap.swift App/Blurt/Blurt/AppCoordinator.swift App/Blurt/Blurt/AppDelegate.swift
git commit -m "feat(app): wire Prompt Inspector capture and hotkey open

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: End-to-end verification via the signed dev build

**Files:** none (manual verification using `scripts/dev-build.sh`).

This is the answer to the original question — `scripts/dev-build.sh` produces the signed, `/Applications`-installed build where the global hotkey and Accessibility-backed tap actually work (DerivedData/tmp paths never register TCC grants).

- [ ] **Step 1: Run the full check gate**

Run: `scripts/check.sh`
Expected: green (swift tests incl. the two new engine tests, coverage gate, xcodegen drift, app build, linters).

- [ ] **Step 2: Build and install the dev app**

Run: `scripts/dev-build.sh`
Expected: "Done. Launch with: open -a Blurt" — a signed Blurt.app installed to `/Applications` (or `~/Applications` fallback).

- [ ] **Step 3: Smoke-test the feature**

1. `open -a Blurt`, grant Accessibility + Microphone if prompted, and add a valid API key so the tap installs (readiness → `showOverlay()` installs the tap).
2. Switch to another app (e.g. Notes), dictate a sentence with the trigger key, and let it paste.
3. Press **⌃⌥⌘P**. Expected: the "Prompt Inspector" window opens frontmost showing the fully-assembled prompt (monospaced, selectable) with a timestamp; **Copy** puts it on the clipboard.
4. Before any dictation (relaunch, then press ⌃⌥⌘P): expect the "No prompt captured yet…" empty state.
5. Close with ⌘W; press ⌃⌥⌘P again — it reopens.

- [ ] **Step 4: Confirm release gating**

Since the feature is intentionally in Release: skim `git grep -n "PromptInspector\|onPromptAssembled\|InspectorHotkey"` and confirm none of the new code sits inside a `#if DEBUG` / `#if UITEST_HOOKS` block. Expected: all unconditional.

---

## Self-Review

**Spec coverage:**
- "Ships in release / undocumented hotkey" → Tasks 2–4 (no gating), verified Task 5 Step 4. ✓
- "Show last-sent, fully-assembled prompt" → Task 1 captures at build site; Task 3 renders. ✓
- "In-memory only, no disk" → Task 3 `PromptInspector` (no persistence). ✓
- "No new event tap / permissions; reuse `DictationKeyTap`" → Task 4 Step 2. ✓
- "Hotkey ⌃⌥⌘P (keycode 35 + ctrl/opt/cmd)" → Task 2 `InspectorHotkey`, Global Constraints. ✓
- "Opens/focuses, close ⌘W" → Task 4 Step 4 + Task 3 scene `.suppressed`. ✓
- "Copy button, empty state, timestamp" → Task 3 view. ✓
- "Tests in Swift Testing; engine-hosted" → Tasks 1–2. Deviation from the spec's "`#if UITEST_HOOKS` simulate seam" note: the App layer has no unit-test target, so the testable logic (chord match, capture wiring) is unit-tested in the engine and the app glue is build- + smoke-verified. Documented in Global Constraints and Task 3/4 notes. ✓
- "New files → xcodegen generate, no pbxproj hand-edit" → Task 3 Step 4. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code and every command shows expected output. ✓

**Type consistency:** `onPromptAssembled: (@Sendable (String?) -> Void)?` (Task 1) matches its call in Task 4 Step 1. `InspectorHotkey.matches(keyCode:flags:)` (Task 2) matches its call in Task 4 Step 2. `PromptInspector.shared.record(_:)` and `PromptInspectorWindow.id` (Task 3) match Task 4 Steps 1 & 4. `onInspector: @MainActor () -> Void` is consistent across `DictationKeyTap`, `AppCoordinator`, and `AppDelegate` (Task 4). ✓
