import AppKit
import ApplicationServices
import CoreGraphics

public actor KeyInjector: InjectorProtocol {
  private var targetApp: NSRunningApplication?

  /// How long to wait after posting Cmd-V before clearing and restoring the
  /// pasteboard. The paste is asynchronous: clear too soon and a slow target
  /// (VNC/Remote Desktop, heavy Electron apps) reads an already-cleared
  /// clipboard. 400 ms is a pragmatic margin over local apps' near-instant read.
  /// This wait runs in a background settle task (see `pendingSettle`), *not* on
  /// `insert`'s caller, so it no longer delays the pipeline re-arming.
  private let pasteSettleDuration: Duration

  /// Synthesizes the paste keystroke. Returns `false` if the event subsystem
  /// couldn't build the events. Injectable so tests exercise the clipboard
  /// save/restore logic without posting a real Cmd-V into the focused app.
  private let postPaste: @Sendable () -> Bool

  /// The exact text most recently pasted by `insert` (including any leading
  /// separator space it added), so a following dictation into the same
  /// Accessibility-opaque editor can recover its spacing (see `separatorBasis`).
  private var lastInsertedText: String?

  /// The pid of the target app `lastInsertedText` was pasted into. Lets `insert`
  /// recover spacing in Accessibility-opaque editors (Electron/Monaco, e.g. VS
  /// Code) where no prior text can be read: if the next dictation targets the
  /// same app, the text we just pasted is what now precedes the caret, so it
  /// drives the separator decision (see `separatorBasis`).
  private var lastInsertedTargetPID: pid_t?

  /// Tail of the paste chain: each insert links behind the previous insert's
  /// ENTIRE critical section — paste *plus* its backgrounded settle/restore — so
  /// two pastes can never interleave on the global `NSPasteboard`. `insert`
  /// itself returns as soon as its paste is posted (the settle trails inside the
  /// chain link), so the pipeline re-arms immediately while the next paste still
  /// waits out the restore window. Chaining replaces a hand-rolled continuation
  /// mutex whose lock had to be handed off to the settle task. Exposed
  /// (internal get) so tests can await the deferred restore before asserting
  /// clipboard state; production never reads it.
  private(set) var pendingSettle: Task<Void, Never>?

  /// What a successful paste hands to its deferred settle: the pre-paste
  /// clipboard snapshot to restore and the change count our own write produced.
  private struct SettleJob: Sendable {
    let savedItems: [SendablePasteboardItem]
    let ourChangeCount: Int
  }

  /// Brings the captured target app back to the foreground before pasting.
  /// Injectable so tests can cover activation failure without depending on
  /// another live application.
  private let activateTarget: @Sendable (NSRunningApplication) -> Bool

  /// Waits until the app activation has actually become visible to
  /// `NSWorkspace` before editability is checked and Cmd-V is posted. Kept
  /// injectable so tests that stub activation don't depend on the host's live
  /// foreground app.
  private let waitForTargetActivation: @Sendable (NSRunningApplication) async -> Bool

  /// Whether the process is trusted for Accessibility. Posting the synthesized
  /// Cmd-V requires it (macOS 10.14+); without it `CGEvent.post` is silently
  /// dropped, so we check first and fail loudly instead of reporting a paste that
  /// never happened. Injectable so tests don't depend on the host's AX state
  /// (defaults to trusted there).
  private let isAccessibilityTrusted: @Sendable () -> Bool

  /// Whether something editable is focused to receive the paste. Checked right
  /// before the synthesized ⌘V (after the target app is activated): when false,
  /// the paste is skipped and the transcript is left on the clipboard instead of
  /// beeping into a non-editable target. Injectable so tests don't depend on the
  /// host's live focus (defaults to "editable" there).
  private let hasEditableTarget: @Sendable () -> Bool

  /// Whether the captured target app is an AX-opaque Electron/Chromium editor
  /// (VS Code, Slack), which exposes no editable AX signal even for a real text
  /// field. When `hasEditableTarget` reads false but this is true, we still paste
  /// rather than copy — dropping the user's words into an Electron editor they're
  /// clearly typing in would be the worse mistake. Injectable so tests don't
  /// depend on which apps are installed (defaults to "not Electron").
  private let isAXOpaqueEditor: @Sendable (NSRunningApplication?) -> Bool

  /// The pasteboard the paste reads, writes, and restores. Behind a seam so
  /// tests exercise the save/restore + changeCount logic against an in-memory
  /// fake instead of the real system pasteboard — whose contents another process
  /// can change mid-test, which (correctly) suppresses the restore and would
  /// otherwise flake.
  private let clipboard: any ClipboardAccess

  public init(pasteSettleDuration: Duration = .milliseconds(400)) {
    self.init(
      pasteSettleDuration: pasteSettleDuration,
      postPaste: KeyInjector.postCmdV,
      activateTarget: KeyInjector.activate,
      waitForTargetActivation: KeyInjector.waitUntilFrontmost,
      isAccessibilityTrusted: KeyInjector.accessibilityTrusted,
      hasEditableTarget: FocusCapture.hasEditableFocusedElement,
      isAXOpaqueEditor: FocusCapture.isElectronApp)
  }

  init(
    pasteSettleDuration: Duration,
    postPaste: @escaping @Sendable () -> Bool,
    activateTarget: @escaping @Sendable (NSRunningApplication) -> Bool = KeyInjector.activate,
    waitForTargetActivation: @escaping @Sendable (NSRunningApplication) async -> Bool = { _ in true },
    isAccessibilityTrusted: @escaping @Sendable () -> Bool = { true },
    hasEditableTarget: @escaping @Sendable () -> Bool = { true },
    isAXOpaqueEditor: @escaping @Sendable (NSRunningApplication?) -> Bool = { _ in false },
    clipboard: any ClipboardAccess = SystemClipboard()
  ) {
    self.pasteSettleDuration = pasteSettleDuration
    self.postPaste = postPaste
    self.activateTarget = activateTarget
    self.waitForTargetActivation = waitForTargetActivation
    self.isAccessibilityTrusted = isAccessibilityTrusted
    self.hasEditableTarget = hasEditableTarget
    self.isAXOpaqueEditor = isAXOpaqueEditor
    self.clipboard = clipboard
  }

  /// Joins `text` to whatever precedes the caret with exactly one separating space,
  /// so consecutive dictations don't run together. Prepends a *leading* space only
  /// when there's preceding text (`priorText`) that doesn't already end in
  /// whitespace; leaves `text` untouched for an empty/unknown field or when the
  /// caret already follows whitespace.
  ///
  /// A leading separator beats a trailing one: a trailing space dangles at the end
  /// of a paste where many text engines trim or collapse it (so the next paste
  /// abuts the previous text), whereas a leading space lands *between* the two
  /// chunks where nothing strips it. `priorText` is nil for empty fields and for
  /// secure/Accessibility-opaque fields — there we can't tell what precedes the
  /// caret, so we add no separator rather than risk a stray leading space.
  public static func withLeadingSeparator(_ text: String, after priorText: String?) -> String {
    guard !text.isEmpty else { return text }
    guard let priorText, let last = priorText.last, !last.isWhitespace else { return text }
    guard let first = text.first, !first.isWhitespace else { return text }
    return " " + text
  }

  /// Chooses what text the separator decision should treat as preceding the
  /// caret. AX-read `priorText` is authoritative whenever we have it. When it's
  /// nil — the field is empty *or* Accessibility-opaque (Electron/Monaco, e.g. VS
  /// Code) — we can't tell those apart from AX alone, so we fall back to the text
  /// we last pasted, but only when this dictation targets the *same continuous
  /// editor*: that's the in-progress-run case where our own paste is what now
  /// sits before the caret. A shared PID alone doesn't establish that — a
  /// browser hosts many independent tabs/documents under one process, so
  /// `sameApp` must be paired with `isKnownOpaqueEditor` (true only for the
  /// Electron-style apps this fallback was built for). Otherwise (a different
  /// target app, a browser tab, or nothing pasted yet) we return nil rather than
  /// risk a stray leading space into what may be a genuinely fresh field.
  static func separatorBasis(
    priorText: String?, lastInserted: String?, sameApp: Bool, isKnownOpaqueEditor: Bool
  ) -> String? {
    if priorText != nil { return priorText }
    return sameApp && isKnownOpaqueEditor ? lastInserted : nil
  }

  public func setTargetApp(_ app: NSRunningApplication?) async {
    targetApp = app
  }

  /// Brings the captured target app frontmost before a paste, then waits a beat
  /// for the activation to settle. No-op when no target was captured. Throws
  /// `.targetAppLost` if the app quit between capture and now, or if activation
  /// fails — pasting into whatever currently has focus would land the
  /// keystrokes in the wrong place. (`performInsert` puts the transcript on the
  /// clipboard before letting this error propagate, so the words survive.)
  /// Takes the target as a parameter (the caller's snapshot) rather than
  /// re-reading `targetApp`, so a `setTargetApp` racing in across the settle
  /// sleep can't swap it mid-paste.
  private func activateTargetApp(_ target: NSRunningApplication?) async throws(BlurtError) {
    guard let target else { return }
    guard !target.isTerminated else { throw BlurtError.targetAppLost }
    guard activateTarget(target) else { throw BlurtError.targetAppLost }
    guard await waitForTargetActivation(target) else { throw BlurtError.targetAppLost }
  }

  public func insert(_ text: String, after priorText: String? = nil) async throws {
    guard !text.isEmpty else { return }
    // Serialize the whole paste critical section by chaining behind the previous
    // insert's link (which includes its settle/restore — see `pendingSettle`).
    // The actor is reentrant across the `await`s in `performInsert`, so an
    // unserialized second insert would snapshot the pasteboard while it still
    // holds this insert's transcript and later restore that instead of the
    // user's original clipboard.
    let previous = pendingSettle
    let timeout = pasteSettleDuration
    let paste = Task<SettleJob?, any Error> {
      await previous?.value
      return try await self.performInsert(text, after: priorText)
    }
    // Strong `self` captures, deliberately: each link is bounded (one paste, one
    // settle sleep — no cycle), and a weak capture would let an injector torn
    // down mid-window skip the restore, leaving the transcript on the clipboard
    // instead of the user's saved contents.
    pendingSettle = Task {
      guard let job = try? await paste.value else { return }
      try? await Task.sleep(for: timeout)
      // No `await`: the task captures the actor's `self`, so it inherits this
      // actor's isolation and the call is synchronous.
      self.finishSettle(savedItems: job.savedItems, ourChangeCount: job.ourChangeCount)
    }
    // Forward the caller's cancellation into the chain link: the paste task is
    // unstructured, so `pipelineTask.cancel()` in the session wouldn't otherwise
    // reach `performInsert`'s cancellation gates.
    try await withTaskCancellationHandler {
      _ = try await paste.value
    } onCancel: {
      paste.cancel()
    }
  }

  /// The paste critical section: runs with the chain's guarantee that no other
  /// insert (or its settle) is mid-flight. Returns the settle job for the
  /// deferred clipboard restore.
  private func performInsert(_ text: String, after priorText: String?) async throws -> SettleJob {
    try Task.checkCancellation()
    // Snapshot the target at entry and use only the local below: this method
    // suspends (activation settle), the actor is reentrant, and a
    // setTargetApp() interleaving mid-insert must not make us activate one app
    // while judging editability and recording `lastInsertedTargetPID` for
    // another.
    let target = targetApp
    // In Accessibility-opaque editors `priorText` is nil even mid-run; fall back
    // to what we last pasted when this dictation targets the same app *and*
    // that app is a known single-continuous-editor case (Electron), so
    // consecutive dictations there still get a separating space. A browser
    // sharing one PID across unrelated tabs/documents (e.g. Google Docs, whose
    // canvas-rendered body also reads as AX-opaque) must not take this
    // fallback — it would carry spacing from a completely unrelated field.
    let sameApp = lastInsertedTargetPID != nil && target?.processIdentifier == lastInsertedTargetPID
    let basis = KeyInjector.separatorBasis(
      priorText: priorText, lastInserted: lastInsertedText, sameApp: sameApp,
      isKnownOpaqueEditor: isAXOpaqueEditor(target))
    let finalText = KeyInjector.withLeadingSeparator(text, after: basis)
    do {
      try await activateTargetApp(target)
    } catch {
      // The target app quit or refused activation between capture and paste.
      // Transcription already succeeded, so leave the words on the clipboard —
      // the pipeline degrades this to the quiet "copied" notice instead of a
      // hard failure that would lose the dictation.
      clipboard.setString(finalText)
      throw error
    }
    // Final cancellation gate before the irreversible paste: a cancel() that
    // landed during activation must not type into the focused app.
    try Task.checkCancellation()
    // Nothing editable is focused (checked now that the target app is frontmost):
    // a synthesized ⌘V would just make macOS beep. Leave the transcript on the
    // clipboard so the user can paste it by hand, and signal the pipeline to show
    // a quiet "copied" notice instead of typing. The exception is an AX-opaque
    // Electron editor (VS Code, Slack), which reports no editable signal even for
    // a real text field — there we still paste rather than drop the user's words.
    guard hasEditableTarget() || isAXOpaqueEditor(target) else {
      clipboard.setString(finalText)
      throw BlurtError.noEditableTarget
    }
    // Bail before touching the pasteboard if we can't actually paste: without
    // Accessibility trust the Cmd-V post below is silently dropped, which would
    // otherwise clobber-and-restore the clipboard for a paste that never lands.
    guard isAccessibilityTrusted() else { throw BlurtError.accessibilityPermissionMissing }

    let savedItems = clipboard.currentItems()
    clipboard.setString(finalText)
    // Snapshot the change count our own write produced. If anything else writes
    // to the pasteboard during the settle window (e.g. the user copies
    // something), the count moves and the deferred restore leaves their newer
    // contents alone rather than clobbering them with the stale pre-paste snapshot.
    let ourChangeCount = clipboard.changeCount
    // If the event subsystem won't synthesize the keystroke, the paste can't
    // happen. The transcript is already on the pasteboard — leave it there (the
    // user's words beat the stale pre-paste snapshot) so the failure degrades
    // to the "copied" notice, matching the lost-target path above.
    guard postPaste() else { throw BlurtError.targetAppLost }
    // The paste is posted and the text is visible. Record what landed (including
    // any leading separator) and which app it landed in so a following dictation
    // into the same opaque editor can recover its spacing, then hand the settle +
    // clipboard restore back to the chain link (see `insert`). `insert` returns
    // now — so the pipeline reaches `.idle` and re-arms without waiting out the
    // restore window — while the next paste still serializes behind the settle.
    lastInsertedText = finalText
    lastInsertedTargetPID = target?.processIdentifier
    return SettleJob(savedItems: savedItems, ourChangeCount: ourChangeCount)
  }

  /// Background tail of a successful `insert`: restore the user's clipboard
  /// (unless another writer changed it during the settle window — then leave the
  /// newer contents alone).
  private func finishSettle(savedItems: [SendablePasteboardItem], ourChangeCount: Int) {
    if clipboard.changeCount == ourChangeCount {
      clipboard.restore(savedItems)
    }
  }

  private static func activate(_ app: NSRunningApplication) -> Bool {
    app.activate()
  }

  private static func waitUntilFrontmost(_ app: NSRunningApplication) async -> Bool {
    let pid = app.processIdentifier
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(350))
    while clock.now < deadline {
      if await MainActor.run(body: { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }) {
        return true
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await MainActor.run {
      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }
  }

  private static func accessibilityTrusted() -> Bool {
    AXIsProcessTrusted()
  }

  /// Posts Cmd-V. Returns `false` if the events couldn't be built. The real side
  /// effect (a keystroke into the focused app) is why this is the injectable seam
  /// tests replace.
  private static func postCmdV() -> Bool {
    let vKey: CGKeyCode = 0x09  // kVK_ANSI_V
    guard let source = CGEventSource(stateID: .combinedSessionState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
    else { return false }
    down.flags = .maskCommand
    up.flags = .maskCommand
    // Post to the annotated session tap rather than the HID tap: the session tap
    // honors exactly the flags set above instead of OR-ing in the live hardware
    // modifier state, so a still-held hotkey modifier can't corrupt Cmd-V into a
    // combo the target app ignores. (We deliberately don't suppress local events
    // during the post: `setLocalEventsFilterDuringSuppressionState` lingers for
    // the source's ~0.25s suppression interval and would swallow the user's next
    // dictation keypress right after a paste — the annotated tap already prevents
    // the modifier merge that suppression was guarding against.)
    down.post(tap: .cgAnnotatedSessionEventTap)
    up.post(tap: .cgAnnotatedSessionEventTap)
    return true
  }

}
