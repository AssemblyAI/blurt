#if os(macOS)
  import AppKit
  import ApplicationServices
  import CoreGraphics

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
      let app = AXRead.app(pid)
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
        AXRead.app(pid), enhancedUserInterface as CFString, kCFBooleanFalse)
    }

    /// The frontmost app's focused window as the planner sees it, numbering
    /// its actionable elements into `snapshot`. Labels only: a field's
    /// contents and a password field are never read.
    ///
    /// A window holding a web page is read in two walks, the page getting
    /// most of the list (`ScreenSnapshot.webShare`), and a page still being
    /// built — Chrome fills its tree in after the first read — is looked at
    /// again. An Electron app is first switched to building its tree at all.
    /// The window's own node is read once and shared, so the walk reuses what
    /// the web-area search read. A read that's cancelled — the command was
    /// abandoned, or a newer one started — stops, and numbers nothing.
    static func readScreen(
      appName: String?, pid: pid_t, isChromium: Bool, isElectron: Bool, into snapshot: ElementSnapshot
    ) async -> ScreenContext {
      let app = AXRead.app(pid)
      // Switched on just now, an Electron app builds its tree after this
      // read, as Chrome does: 1Password answered with nothing (2026-11-04).
      let justSwitchedOn = isElectron && snapshot.claimManualAccessibility(pid)
      if justSwitchedOn {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
      }
      let buildsLate = isChromium || justSwitchedOn
      guard let element = AXRead.window(of: app) else {
        snapshot.replace(pid: pid, elements: [:])
        return ScreenContext(appName: appName)
      }
      var window = AXRead.Node(element)
      var webArea = largest(role: "AXWebArea", in: window)
      // A Chromium browser whose page tree is still being built has no web
      // area yet: the user spoke faster than its ~2 s build. Wait for it, on
      // a fresh read of the window each time — the tree is changing.
      if buildsLate {
        for delay in ScreenSnapshot.webAreaWaits where webArea == nil {
          guard await pause(delay) else { return ScreenContext(appName: appName) }
          window = AXRead.Node(element)
          webArea = largest(role: "AXWebArea", in: window)
        }
      }
      var pageIncomplete = false
      func walkPage(_ area: AXRead.Node) -> [ScreenSnapshot.Entry<AXRead.Node>] {
        pageIncomplete = false
        return ScreenRead.walkPage(area, window: window, shouldStop: budget(), incomplete: &pageIncomplete)
      }
      var page = webArea.map(walkPage) ?? []
      // Only a browser, or an Electron app just switched on, builds its page
      // after the first read; otherwise a sparse web area is just a small
      // one, and waiting costs a second.
      if let area = webArea?.element, buildsLate {
        for delay in ScreenSnapshot.webRetryDelays where page.count < ScreenSnapshot.sparseWebArea {
          guard await pause(delay) else { return ScreenContext(appName: appName) }
          page = walkPage(AXRead.Node(area))
        }
      }
      // The page's share and the window's, shared as `ScreenRead.listing` says.
      let listing = ScreenRead.listing(
        window: window, webArea: webArea, page: (page, pageIncomplete), same: { CFEqual($0.element, $1.element) },
        shouldStop: budget())
      guard !Task.isCancelled else { return ScreenContext(appName: appName) }
      return ScreenContext(
        appName: appName, windowTitle: window.string(kAXTitleAttribute),
        elements: number(listing.entries, pid: pid, into: snapshot), incomplete: listing.incomplete)
    }

    /// Sleeps `delay`, answering false — at once — when the read is cancelled:
    /// a cancelled sleep that's merely ignored would run the waits and walks
    /// after it back to back, against the read still wanted.
    private static func pause(_ delay: Duration) async -> Bool {
      do {
        try await Task.sleep(for: delay)
        return true
      } catch {
        return false
      }
    }

    /// `ScreenRead.largest`, bounded by `ScreenSnapshot.webAreaSearchBudget`
    /// — a window with none (Music has no web area) is otherwise searched node
    /// by node, and Music answers at ~15 ms a call.
    static func largest(role: String, in root: AXRead.Node) -> AXRead.Node? {
      let deadline = ContinuousClock.now.advanced(by: ScreenSnapshot.webAreaSearchBudget)
      return ScreenRead.largest(
        role: role, in: root, shouldStop: { ContinuousClock.now >= deadline || Task.isCancelled })
    }

    /// Stops a walk at `ScreenSnapshot.readBudget`, or when the read is cancelled.
    private static func budget() -> () -> Bool {
      let deadline = ContinuousClock.now.advanced(by: ScreenSnapshot.readBudget)
      return { ContinuousClock.now >= deadline || Task.isCancelled }
    }

    /// Numbers the entries from 1, keeping each one's element in `snapshot`
    /// for the steps that name it.
    private static func number(
      _ entries: [ScreenSnapshot.Entry<AXRead.Node>], pid: pid_t, into snapshot: ElementSnapshot
    ) -> [ScreenContext.Element] {
      var elements: [Int: ElementSnapshot.Handle] = [:]
      var listed: [ScreenContext.Element] = []
      for (offset, entry) in entries.enumerated() {
        let id = offset + 1
        elements[id] = ElementSnapshot.Handle(element: entry.node.element)
        listed.append(ScreenContext.Element(id: id, kind: entry.kind, label: entry.label))
      }
      snapshot.replace(pid: pid, elements: elements)
      return listed
    }

    // MARK: - Acting on an element

    /// Presses the listed element, or puts the cursor in it (`focus`).
    /// Refused when the app in front isn't the one the snapshot read.
    static func act(on id: Int, in snapshot: ElementSnapshot, focus: Bool) async throws -> String {
      let pid = await frontmostPID()
      let handle = try snapshot.element(id, pid: pid)
      return focus ? try await self.focus(handle, pid: pid) : try await press(handle, pid: pid)
    }

    /// `AXPress`, then a real click at its centre when the element refuses
    /// the press (a web element exposed with no action) — and, in Chromium
    /// and Electron (`checksPress`), when the press reports success but
    /// nothing changed (`PressFingerprint`): Chrome answers success for a
    /// press its page ignored. Owner-directed (2026-11-03), knowing the cost
    /// there: a control that worked without changing anything Blurt can see
    /// — a Send whose window stays put — is pressed twice. Refused, either
    /// way, when its label marks it as destructive.
    static func press(_ handle: ElementSnapshot.Handle, pid: pid_t?) async throws -> String {
      let node = AXRead.Node(handle.element)
      try refuseIfDestructive(node)
      return try await checked(
        "AXPress", node: node, pid: pid,
        press: { AXUIElementPerformAction(handle.element, kAXPressAction as CFString) == .success })
    }

    /// `ElementActions.press` with this app's reads: the fingerprint only
    /// where a success can't be trusted (`checksPress`); the first reuses the
    /// node the caller read, the second reads the element again.
    static func checked(
      _ action: String, node: AXRead.Node, pid: pid_t?, always: Bool = false, press: () -> Bool
    ) async throws -> String {
      // Selecting is harmless to repeat, so `always` checks it in any app.
      let checks = await checksPress(pid)
      let verify = always || checks
      var pressed = false
      let read = {
        defer { pressed = true }
        return fingerprint(of: pressed ? AXRead.Node(node.element) : node, pid: pid)
      }
      return try await ElementActions.press(
        action, fingerprint: verify ? read : nil, press: press,
        settle: { try await Task.sleep(for: pressSettle) }, click: { try await click(node, pid: pid) })
    }

    /// Whether an action's success needs checking for: Chromium browsers and
    /// Electron apps, whose web content can answer success and do nothing.
    static func checksPress(_ pid: pid_t?) async -> Bool {
      await MainActor.run {
        guard let app = pid.flatMap(NSRunningApplication.init(processIdentifier:)) else { return false }
        return app.bundleIdentifier.map(ScreenSnapshot.chromiumBrowsers.contains) == true
          || FocusCapture.isElectronBundle(app.bundleURL)
      }
    }

    /// Every Accessibility action Blurt performs on an element on screen — a
    /// menu item's press, a step, a context menu — goes through here, or
    /// through `press` and `click`, which check the same way: refused when the
    /// element's name marks it as destructive.
    static func performAction(_ action: String, on node: AXRead.Node) throws -> AXError {
      try refuseIfDestructive(node)
      return AXUIElementPerformAction(node.element, action as CFString)
    }

    /// Refuses an element whose name marks it as destructive (`DestructiveGuard`).
    static func refuseIfDestructive(_ node: AXRead.Node) throws {
      let labels = AXRead.names(node)
      guard !labels.contains(where: DestructiveGuard.isDestructive(label:)) else {
        throw VoiceCommandError.refused("press \(labels.first ?? "that")")
      }
    }

    /// Refuses a step on an element whose role isn't one it acts on
    /// (`ScreenSnapshot.textEntryRoles` for a focus, `selectableRoles`,
    /// `adjustableRoles`) before it could fall back to a click on, say, a
    /// button. Answers the role it read — empty when the app didn't answer
    /// in time (Mail, just launched, 2026-11-04): the plan was already held
    /// to the kind the element was listed under, so that's trusted rather
    /// than the step refused over a read that timed out.
    @discardableResult
    static func require(_ node: AXRead.Node, roleIn roles: Set<String>, for step: String, what: String) throws -> String
    {
      guard let role = node.role else { return "" }
      guard roles.contains(role) else { throw VoiceCommandError.couldNotPerform("\(step) that: it isn't \(what)") }
      return role
    }

    /// How long a press gets to show before it's taken as ignored.
    static let pressSettle: Duration = .milliseconds(250)

    /// What a press that worked would most likely change, read the same way
    /// before and after it.
    private static func fingerprint(of node: AXRead.Node, pid: pid_t?) -> PressFingerprint {
      let app = pid.map(AXRead.app)
      let focused = app.flatMap { AXRead.element($0, kAXFocusedUIElementAttribute) }
      let window = app.flatMap { AXRead.element($0, kAXFocusedWindowAttribute) }
      return PressFingerprint(
        focusedElement: focused.map { Int(CFHash($0)) },
        windowTitle: window.flatMap { AXRead.string($0, kAXTitleAttribute) },
        value: AXRead.string(node.element, kAXValueAttribute),
        onScreen: node.frame != nil, focusOnTarget: focused.map { isWithin($0, node.element) } ?? false,
        expanded: AXRead.bool(node.element, "AXExpanded"))
    }

    /// Whether a window owned by `owner` is `pid`'s own: its own, or an
    /// Open or Save panel AppKit draws for it from a service process — a
    /// sandboxed app's panels are owned there, not by the app.
    static func isOwn(_ owner: Int, of pid: pid_t) -> Bool {
      owner == Int(pid)
        || NSRunningApplication(processIdentifier: pid_t(owner))?.bundleIdentifier?.hasPrefix("com.apple.appkit.xpc.")
          == true
    }

    /// Whether `element` is `target` or sits a few levels inside it: the
    /// row's inner group can be what takes the focus.
    private static func isWithin(_ element: AXUIElement, _ target: AXUIElement) -> Bool {
      var current: AXUIElement? = element
      for _ in 0..<4 {
        guard let level = current else { return false }
        if CFEqual(level, target) { return true }
        current = AXRead.element(level, kAXParentAttribute)
      }
      return false
    }

    /// Focus through Accessibility, checked: if the app's focused element
    /// isn't the field afterwards (a web input can take the attribute and
    /// ignore it), a click puts the cursor there instead. Then a single-line
    /// field's contents are selected — but only once it's confirmed focused,
    /// since a selection lands wherever the cursor is.
    private static func focus(_ handle: ElementSnapshot.Handle, pid: pid_t?) async throws -> String {
      let node = AXRead.Node(handle.element)
      // A search field shown as its button (Finder's): pressing it opens the
      // field, focused, which is what a focus on it is for.
      if node.role == kAXButtonRole, AXRead.string(handle.element, kAXSubroleAttribute) == "AXSearchField" {
        return try await press(handle, pid: pid) + "; a search button, opened"
      }
      let role = try require(node, roleIn: ScreenSnapshot.textEntryRoles, for: "focus", what: "a text field")
      return try await ElementActions.focus(
        singleLine: ScreenSnapshot.singleLineEntryRoles.contains(role),
        setFocus: {
          AXUIElementSetAttributeValue(handle.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
          try await Task.sleep(for: .milliseconds(100))
        },
        isFocused: { isFocused(handle.element, pid: pid) },
        click: { try await click(node, pid: pid) },
        selectAll: { selectAll(handle.element) })
    }

    private static func isFocused(_ element: AXUIElement, pid: pid_t?) -> Bool {
      guard let focused = pid.flatMap({ AXRead.element(AXRead.app($0), kAXFocusedUIElementAttribute) }) else {
        return false
      }
      return CFEqual(focused, element)
    }

    /// Selects a focused single-line field's whole contents, as tabbing into a
    /// field or clicking into Chrome's address bar does: a typed step then
    /// replaces what's there — a URL, a search — rather than landing in the
    /// middle of it, where the cursor a focus leaves can be (measured in
    /// Chrome's address bar, 2026-11-03). By the field's length
    /// (`AXNumberOfCharacters`), never its text. A field that won't take a
    /// range keeps its cursor: no ⌘A, which would select whatever has focus.
    private static func selectAll(_ field: AXUIElement) -> String {
      guard let count = AXRead.value(field, kAXNumberOfCharactersAttribute) as? Int else {
        return "no character count, nothing selected"
      }
      var range = CFRange(location: 0, length: count)
      guard let value = AXValueCreate(.cfRange, &range),
        AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value) == .success
      else { return "selection refused, cursor kept" }
      return "selected \(count) characters"
    }

    /// A left click at the element's centre, scrolled into view first, posted
    /// as the HID events a mouse sends; the pointer goes back where it was.
    /// Only with the snapshot's app still in front and the centre inside the
    /// element's window (`ScreenSnapshot.clickPoint`), and never on a
    /// destructive element.
    static func click(_ node: AXRead.Node, pid: pid_t?) async throws {
      try refuseIfDestructive(node)
      AXUIElementPerformAction(node.element, "AXScrollToVisible" as CFString)
      // Read again: scrolling into view moved it.
      guard let frame = AXRead.frame(node.element),
        let window = AXRead.element(node.element, kAXWindowAttribute), let bounds = AXRead.frame(window),
        let point = ScreenSnapshot.clickPoint(frame, within: bounds)
      else { throw VoiceCommandError.elementGone }
      let front = await frontmostPID()
      guard let pid, front == pid else { throw VoiceCommandError.screenChanged }
      // And its window must be the one on top there: in front isn't enough
      // while another app's window still covers the spot.
      guard let owner = WindowOrder.owner(at: point, in: onScreenWindows()), isOwn(owner, of: pid) else {
        throw VoiceCommandError.screenChanged
      }
      try await withPointer(at: point) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
          guard
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
          else { throw VoiceCommandError.couldNotPerform("click there") }
          event.post(tap: .cghidEventTap)
        }
      }
    }
  }
#endif
