#if os(macOS)
  import AppKit
  import ApplicationServices
  import CoreGraphics
  import Synchronization

  /// The elements one `screenContext()` numbered, and the app they belong to:
  /// a `press` or `focus` step acts on the element its number was read from,
  /// never on whatever is at that place now. Replaced by each snapshot.
  final class ElementSnapshot: Sendable {
    /// An element reference carried across threads. Unchecked because
    /// `AXUIElement` doesn't declare it, though it is an immutable CF handle
    /// the Accessibility API takes from any thread (the paste's AX reads run
    /// off the main thread too).
    struct Handle: @unchecked Sendable {
      let element: AXUIElement
    }

    private struct State {
      var pid: pid_t
      var elements: [Int: Handle]
    }

    private let state = Mutex<State?>(nil)
    /// The Electron apps already switched to building their tree: the switch
    /// costs the app two seconds of work each time it flips, so it's set
    /// once per process and left on.
    private let manualAccessibility = Mutex<Set<pid_t>>([])

    func replace(pid: pid_t, elements: [Int: Handle]) {
      state.withLock { $0 = State(pid: pid, elements: elements) }
    }

    /// The element numbered `id`, if this snapshot listed it and `pid` is
    /// still the app it was read from.
    func element(_ id: Int, pid: pid_t?) throws -> Handle {
      try state.withLock { state in
        guard let state else { throw VoiceCommandError.unknownElement(id) }
        guard state.pid == pid else { throw VoiceCommandError.screenChanged }
        guard let handle = state.elements[id] else { throw VoiceCommandError.unknownElement(id) }
        return handle
      }
    }

    /// Whether `pid` is still to be switched on: true once per process.
    func claimManualAccessibility(_ pid: pid_t) -> Bool {
      manualAccessibility.withLock { $0.insert(pid).inserted }
    }
  }

  /// Which Chromium browser Blurt turned `AXEnhancedUserInterface` on for,
  /// so it clears only what it set — never a flag another tool (Homerow,
  /// Vimac) turned on — and so a lingering clear from an earlier command
  /// can't undo a newer one's.
  final class EnhancedInterface: Sendable {
    private struct State {
      var pid: pid_t?
      var generation = 0
    }

    private let state = Mutex(State())

    /// Records `pid` as Blurt's to clear; answers this claim's generation.
    func claim(_ pid: pid_t) -> Int {
      state.withLock { state in
        state.pid = pid
        state.generation += 1
        return state.generation
      }
    }

    func owns(_ pid: pid_t) -> Bool { state.withLock { $0.pid == pid } }

    /// The pid to clear, if Blurt still holds it — and `generation`, when
    /// given, is still the latest claim.
    func release(generation: Int? = nil) -> pid_t? {
      state.withLock { state in
        guard let pid = state.pid, generation == nil || generation == state.generation else { return nil }
        state.pid = nil
        return pid
      }
    }
  }

  extension SystemVoiceCommandPerformer {
    static let enhancedUserInterface = "AXEnhancedUserInterface"

    /// Turns on a Chromium browser's page tree for the command about to be
    /// spoken, so its ~2 s build runs while the user talks. Cleared at the
    /// command's end (`endEnhancedInterface`), or after
    /// `ScreenSnapshot.enhancedInterfaceLinger` if the press asked nothing:
    /// the flag also slows window managers' moves and resizes, so it stays on
    /// no longer than a command needs. Left alone when it was already on.
    static func beginEnhancedInterface(pid: pid_t, bundleID: String?, in owner: EnhancedInterface) {
      guard let bundleID, ScreenSnapshot.chromiumBrowsers.contains(bundleID) else { return }
      let app = AXUIElementCreateApplication(pid)
      guard owner.owns(pid) || AXRead.bool(app, enhancedUserInterface) != true else { return }
      AXUIElementSetAttributeValue(app, enhancedUserInterface as CFString, kCFBooleanTrue)
      let generation = owner.claim(pid)
      Task {
        try? await Task.sleep(for: ScreenSnapshot.enhancedInterfaceLinger)
        if let pid = owner.release(generation: generation) { clearEnhancedInterface(pid) }
      }
    }

    static func endEnhancedInterface(in owner: EnhancedInterface) {
      if let pid = owner.release() { clearEnhancedInterface(pid) }
    }

    private static func clearEnhancedInterface(_ pid: pid_t) {
      AXUIElementSetAttributeValue(
        AXUIElementCreateApplication(pid), enhancedUserInterface as CFString, kCFBooleanFalse)
    }

    /// The frontmost app's focused window as the planner sees it, numbering
    /// its actionable elements into `snapshot`. Labels only: a field's
    /// contents and a password field are never read.
    ///
    /// A window holding a web page is read in two walks, the page getting
    /// most of the list (`ScreenSnapshot.webShare`), and a page still being
    /// built — Chrome fills its tree in after the first read — is looked at
    /// again. An Electron app is first switched to building its tree at all.
    static func readScreen(
      appName: String?, pid: pid_t, bundleURL: URL?, into snapshot: ElementSnapshot
    ) async -> ScreenContext {
      let app = AXRead.capped(AXUIElementCreateApplication(pid))
      if ScreenSnapshot.isElectron(infoDictionary: bundleURL.flatMap { Bundle(url: $0)?.infoDictionary } ?? [:]),
        snapshot.claimManualAccessibility(pid)
      {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
      }
      guard let window = AXRead.element(app, kAXFocusedWindowAttribute) ?? AXRead.element(app, kAXMainWindowAttribute)
      else {
        snapshot.replace(pid: pid, elements: [:])
        return ScreenContext(appName: appName)
      }
      let windowFrame = AXRead.frame(window)
      var webArea = webArea(in: window)
      // A Chromium browser whose page tree is still being built has no web
      // area yet: the user spoke faster than its ~2 s build. Wait for it.
      if ScreenSnapshot.isChromium(bundleURL: bundleURL) {
        for delay in ScreenSnapshot.webAreaWaits where webArea == nil {
          try? await Task.sleep(for: delay)
          webArea = Self.webArea(in: window)
        }
      }
      var incomplete = false
      var pageIncomplete = false
      var page =
        webArea.map {
          walk($0, bounds: AXRead.frame($0) ?? windowFrame, keep: ScreenSnapshot.webShare, incomplete: &pageIncomplete)
        } ?? []
      // Only a browser builds its page after the first read; an Electron
      // app's sparse web area is just a small one, and waiting costs a second.
      if let webArea, ScreenSnapshot.isChromium(bundleURL: bundleURL) {
        for delay in ScreenSnapshot.webRetryDelays where page.count < ScreenSnapshot.sparseWebArea {
          try? await Task.sleep(for: delay)
          pageIncomplete = false
          page = walk(
            webArea, bounds: AXRead.frame(webArea) ?? windowFrame, keep: ScreenSnapshot.webShare,
            incomplete: &pageIncomplete)
        }
      }
      let around = walk(
        window, bounds: windowFrame, keep: ScreenContext.maxElements - page.count,
        skip: { node in webArea.map { CFEqual(node, $0) } ?? false }, incomplete: &incomplete)
      return ScreenContext(
        appName: appName, windowTitle: AXRead.string(window, kAXTitleAttribute),
        elements: number(around + page, pid: pid, into: snapshot), incomplete: incomplete || pageIncomplete)
    }

    /// The window's largest web area: the page, not an Electron app's
    /// title-bar or sidebar web view (Claude's window holds two). Bounded by
    /// `ScreenSnapshot.webAreaSearchBudget`: a window with none (Music) is
    /// otherwise searched node by node, and Music answers at ~15 ms a call.
    private static func webArea(in window: AXUIElement) -> AXUIElement? {
      var best: (area: AXUIElement, size: CGFloat)?
      let deadline = ContinuousClock.now.advanced(by: ScreenSnapshot.webAreaSearchBudget)
      _ = ScreenSnapshot.entries(
        from: window, children: AXRead.children,
        describe: { node in
          if AXRead.string(node, kAXRoleAttribute) == "AXWebArea" {
            let frame = AXRead.frame(node) ?? .zero
            if best == nil || frame.width * frame.height > best?.size ?? 0 { best = (node, frame.width * frame.height) }
          }
          return nil
        }, visitLimit: 800, shouldStop: { ContinuousClock.now >= deadline })
      return best?.area
    }

    /// One bounded breadth-first walk: each call capped at
    /// `ScreenSnapshot.callTimeout`, the whole at `ScreenSnapshot.readBudget`.
    private static func walk(
      _ root: AXUIElement, bounds: CGRect?, keep: Int, skip: (AXUIElement) -> Bool = { _ in false },
      incomplete: inout Bool
    ) -> [ScreenSnapshot.Entry<AXUIElement>] {
      let deadline = ContinuousClock.now.advanced(by: ScreenSnapshot.readBudget)
      var stopped = false
      let entries = ScreenSnapshot.entries(
        from: root, children: AXRead.children, describe: { AXRead.describe($0, in: bounds) },
        keepLimit: keep, skip: skip, shouldStop: { ContinuousClock.now >= deadline }, onIncomplete: { stopped = true })
      incomplete = incomplete || stopped
      return entries
    }

    /// Numbers the entries from 1, keeping each one's element in `snapshot`
    /// for the steps that name it.
    private static func number(
      _ entries: [ScreenSnapshot.Entry<AXUIElement>], pid: pid_t, into snapshot: ElementSnapshot
    ) -> [ScreenContext.Element] {
      var elements: [Int: ElementSnapshot.Handle] = [:]
      var listed: [ScreenContext.Element] = []
      for (offset, entry) in entries.enumerated() {
        let id = offset + 1
        elements[id] = ElementSnapshot.Handle(element: entry.node)
        listed.append(ScreenContext.Element(id: id, kind: entry.kind, label: entry.label))
      }
      snapshot.replace(pid: pid, elements: elements)
      return listed
    }

    // MARK: - Acting on an element

    /// Presses the listed element, or puts the cursor in it (`focus`).
    /// Refused when the app in front isn't the one the snapshot read.
    static func act(on id: Int, in snapshot: ElementSnapshot, focus: Bool) async throws {
      let pid = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication?.processIdentifier })
      let handle = try snapshot.element(id, pid: pid)
      if focus {
        try await self.focus(handle, pid: pid)
      } else {
        try await press(handle, pid: pid)
      }
    }

    /// `AXPress`, then a real click at its centre when the element refuses
    /// the press (a web element exposed with no action) or the press reports
    /// success but nothing changed (`PressFingerprint`): Chrome answers
    /// success for a press its page ignored. Owner-directed (2026-11-03),
    /// knowing the cost: a control that worked without changing anything
    /// Blurt can see — a Send whose window stays put — is pressed twice.
    /// Refused, either way, when its label marks it as destructive.
    static func press(_ handle: ElementSnapshot.Handle, pid: pid_t?) async throws {
      try refuseIfDestructive(handle.element)
      let before = fingerprint(of: handle.element, pid: pid)
      guard AXUIElementPerformAction(handle.element, kAXPressAction as CFString) == .success else {
        return try await click(handle, pid: pid)
      }
      try await Task.sleep(for: pressSettle)
      guard !fingerprint(of: handle.element, pid: pid).changed(since: before) else { return }
      try await click(handle, pid: pid)
    }

    /// Refuses an element whose name marks it as destructive (`DestructiveGuard`).
    /// Checked before a press and again inside `click`, so no path that ends in
    /// a click — a refused press, a focus or a select falling back — skips it.
    static func refuseIfDestructive(_ element: AXUIElement) throws {
      let labels = AXRead.names(element)
      guard !labels.contains(where: DestructiveGuard.isDestructive(label:)) else {
        throw VoiceCommandError.refused("press \(labels.first ?? "that")")
      }
    }

    /// The roles a `focus` step may put the cursor in, and a `select` step
    /// may select: anything else is refused before it could fall back to a
    /// click on, say, a button.
    static let focusableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    static let selectableRoles: Set<String> = ["AXRow", "AXCell", "AXRadioButton"]

    static func require(_ element: AXUIElement, roleIn roles: Set<String>, for step: String) throws {
      guard let role = AXRead.string(element, kAXRoleAttribute), roles.contains(role) else {
        throw VoiceCommandError.couldNotPerform("\(step) that: it isn't something to \(step)")
      }
    }

    /// How long a press gets to show before it's taken as ignored.
    static let pressSettle: Duration = .milliseconds(250)

    /// What a press that worked would most likely change, read the same way
    /// before and after it.
    private static func fingerprint(of element: AXUIElement, pid: pid_t?) -> PressFingerprint {
      let app = pid.map(AXUIElementCreateApplication)
      let focused = app.flatMap { AXRead.element($0, kAXFocusedUIElementAttribute) }
      let window = app.flatMap { AXRead.element($0, kAXFocusedWindowAttribute) }
      return PressFingerprint(
        focusedElement: focused.map { Int(CFHash($0)) },
        windowTitle: window.flatMap { AXRead.string($0, kAXTitleAttribute) },
        value: AXRead.string(element, kAXValueAttribute),
        onScreen: AXRead.frame(element) != nil)
    }

    /// Focus through Accessibility, checked: if the app's focused element
    /// isn't the field afterwards (a web input can take the attribute and
    /// ignore it), a click puts the cursor there instead.
    private static func focus(_ handle: ElementSnapshot.Handle, pid: pid_t?) async throws {
      try require(handle.element, roleIn: focusableRoles, for: "focus")
      AXUIElementSetAttributeValue(handle.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
      try await Task.sleep(for: .milliseconds(100))
      if let pid,
        let focused = AXRead.element(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
        CFEqual(focused, handle.element)
      {
        return
      }
      try await click(handle, pid: pid)
    }

    /// A left click at the element's centre, scrolled into view first, posted
    /// as the HID events a mouse sends; the pointer goes back where it was.
    /// Only with the snapshot's app still in front and the centre inside the
    /// element's window (`ScreenSnapshot.clickPoint`).
    static func click(_ handle: ElementSnapshot.Handle, pid: pid_t?) async throws {
      try refuseIfDestructive(handle.element)
      AXUIElementPerformAction(handle.element, "AXScrollToVisible" as CFString)
      guard let frame = AXRead.frame(handle.element),
        let window = AXRead.element(handle.element, kAXWindowAttribute), let bounds = AXRead.frame(window),
        let point = ScreenSnapshot.clickPoint(frame, within: bounds)
      else { throw VoiceCommandError.elementGone }
      let front = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication?.processIdentifier })
      guard pid != nil, front == pid else { throw VoiceCommandError.screenChanged }
      let home = CGEvent(source: nil)?.location
      for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        guard
          let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        else { throw VoiceCommandError.couldNotPerform("click there") }
        event.post(tap: .cghidEventTap)
      }
      try await Task.sleep(for: .milliseconds(50))
      if let home { CGWarpMouseCursorPosition(home) }
    }
  }
#endif
