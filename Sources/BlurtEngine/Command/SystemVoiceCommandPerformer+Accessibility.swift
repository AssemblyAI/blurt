#if os(macOS)
  import AppKit
  import ApplicationServices
  import CoreGraphics

  // The steps carried out through Accessibility: raising an app, pressing a
  // button in its window, choosing an item from its menus. All on the trust
  // the paste already has; nothing here needs Screen Recording.
  extension SystemVoiceCommandPerformer {
    /// Makes `pid` the frontmost app through its Accessibility element, as
    /// clicking its Dock icon would. Not gated by cooperative activation, which
    /// is what drops `activate()` from an app that isn't active itself.
    @MainActor
    static func raise(_ pid: pid_t) {
      AXUIElementSetAttributeValue(AXRead.app(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// Whether `app` is really in front, and not only on its way (after
    /// Peekaboo's `isVerifiedApplicationActivation`): the frontmost app and —
    /// when it has a window on screen — owning the topmost one.
    /// `frontmostApplication` flips before the window comes up, and a shortcut
    /// sent in that gap lands in the window still on top. Not `isActive`:
    /// `NSRunningApplication` caches it, and a running Slack failed a command
    /// on it (2026-11-03) that the same checks without it pass in 0.3 s.
    @MainActor
    static func isVerifiedFrontmost(_ app: NSRunningApplication) -> Bool {
      let pid = app.processIdentifier
      guard isFrontmost(pid) else { return false }
      let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      guard let windows = info as? [[String: Any]] else { return true }
      let order = windows.map { window in
        WindowOrder.Window(
          owner: window[kCGWindowOwnerPID as String] as? Int ?? -1,
          layer: window[kCGWindowLayer as String] as? Int ?? -1)
      }
      return WindowOrder.isFrontmost(Int(pid), in: order)
    }

    @MainActor
    static func isFrontmost(_ pid: pid_t) -> Bool {
      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Presses the element named `name` in the frontmost app's focused window
    /// (`ElementSearch` over its Accessibility tree). Off the main actor: each
    /// read is a round trip to the app, and a busy window takes thousands.
    static func pressButton(_ name: String) async throws -> String {
      guard let app = await frontmostApp(),
        let window = AXRead.window(of: app),
        let target = searchBounded(name, in: window)
      else { throw VoiceCommandError.buttonNotFound(name) }
      return try await press(ElementSnapshot.Handle(element: target), pid: pid(of: app))
    }

    /// Chooses the frontmost app's menu item at `path`, from the menu-bar
    /// title down (Hammerspoon's `selectMenuItem`, MIT): an item is pressed
    /// without its menu being opened, so nothing flashes on screen.
    static func chooseMenuItem(_ path: [String]) async throws {
      guard let app = await frontmostApp(), let bar = AXRead.element(app, kAXMenuBarAttribute) else {
        throw VoiceCommandError.menuItemNotFound(path)
      }
      // Each entry's role and title come in one round trip (`Node`).
      let item = try ElementActions.menuItem(
        path, from: AXRead.Node(bar),
        entries: { $0.children.flatMap { $0.role == kAXMenuRole ? $0.children : [$0] } },
        title: { $0.string(kAXTitleAttribute) })
      // A dimmed item is one the app would ignore: say so rather than "Done".
      // Its enabled state and labels come from the node already read.
      guard item.attribute(kAXEnabledAttribute) as? Bool != false,
        try performAction(kAXPressAction, on: item) == .success
      else { throw VoiceCommandError.couldNotPerform("choose \(path.joined(separator: " › "))") }
    }

    /// `ElementSearch` over the window within `ScreenSnapshot.readBudget`: in a
    /// slow app (Music, ~15 ms a call) a search of every node runs for minutes.
    private static func searchBounded(_ name: String, in window: AXUIElement) -> AXUIElement? {
      let deadline = ContinuousClock.now.advanced(by: ScreenSnapshot.readBudget)
      return ElementSearch.best(
        named: name, from: AXRead.Node(window), children: \.children, labels: AXRead.labels,
        pressable: { AXRead.isPressable($0.element) }, shouldStop: { ContinuousClock.now >= deadline })?.element
    }

    static func pid(of element: AXUIElement) -> pid_t? {
      var pid: pid_t = 0
      return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    /// The frontmost app's pid, read on the main actor where `NSWorkspace` lives.
    static func frontmostPID() async -> pid_t? {
      await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }

    /// The frontmost app's element, its calls capped.
    static func frontmostApp() async -> AXUIElement? {
      await frontmostPID().map(AXRead.app)
    }

    /// Runs `body` with the pointer at `point`, then puts it back: a synthesized
    /// click or wheel event goes to what's under the pointer, and the user's
    /// pointer shouldn't stay where Blurt left it.
    static func withPointer(at point: CGPoint, _ body: () throws -> Void) async throws {
      try await ElementActions.withPointer(
        at: point, home: CGEvent(source: nil)?.location, warp: { CGWarpMouseCursorPosition($0) },
        beat: { try await Task.sleep(for: .milliseconds(50)) }, body)
    }
  }

  /// The Accessibility reads the steps make, each nil (or empty) when the
  /// element doesn't answer.
  enum AXRead {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
      return value
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
      value(element, attribute).flatMap(FocusCapture.axElement).map(capped)
    }

    /// `pid`'s application element, its calls capped.
    static func app(_ pid: pid_t) -> AXUIElement {
      capped(AXUIElementCreateApplication(pid))
    }

    /// The app's focused window, else its main one: an app whose main window
    /// isn't key still has one to act in.
    /// The focused window, else the main one, else the first the app lists:
    /// Calculator answered neither of the first two (2026-11-04).
    static func window(of app: AXUIElement) -> AXUIElement? {
      element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
        ?? (value(app, kAXWindowsAttribute) as? [AXUIElement])?.first.map(capped)
    }

    /// `element` with its calls capped at `ScreenSnapshot.callTimeout`. The
    /// cap belongs to each element reference, not the app, and the default
    /// is six seconds: Music took 18 s over one read with three slow answers
    /// (2026-11-03). Every element these reads hand on is capped.
    static func capped(_ element: AXUIElement) -> AXUIElement {
      AXUIElementSetMessagingTimeout(element, ScreenSnapshot.callTimeout)
      return element
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
      FocusCapture.stringValue(element, attribute)
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
      value(element, attribute) as? Bool
    }

    /// What a user would call it: its title, its description (an icon
    /// button's spoken name), and — for a role whose value is its name, a
    /// link's text — its value.
    static func labels(_ node: Node) -> [String] {
      [node.string(kAXTitleAttribute), node.string(kAXDescriptionAttribute), node.nameValue].compactMap { $0 }
    }

    /// The name a web form control borrows from the `<label>` pointing at it.
    static func borrowedLabel(_ node: Node) -> String? {
      node.element(kAXTitleUIElementAttribute).flatMap { labels(Node($0)).first }
    }

    /// Its labels, else the one it borrows, else the text inside it
    /// (`ScreenSnapshot.firstText`). `deadline`: when the read's time is up —
    /// the lookup inside one row can otherwise outrun the whole read, Music's
    /// content rows answering at up to ~130 ms a call (measured 2026-11-03),
    /// since the walk checks its clock only between nodes.
    static func names(_ node: Node, until deadline: ContinuousClock.Instant? = nil) -> [String] {
      let own = labels(node)
      if !own.isEmpty { return own }
      return (borrowedLabel(node) ?? firstText(under: node, until: deadline)).map { [$0] } ?? []
    }

    private static func firstText(under node: Node, until deadline: ContinuousClock.Instant?) -> String? {
      ScreenSnapshot.firstText(
        under: node, children: \.children, role: \.role, text: \.rawValue,
        title: { $0.string(kAXTitleAttribute) ?? $0.string(kAXDescriptionAttribute) },
        shouldStop: { deadline.map { ContinuousClock.now >= $0 } ?? false })
    }

    /// Its frame in global, top-left-origin coordinates — the ones a
    /// `CGEvent` click takes — in one round trip for the two attributes.
    static func frame(_ element: AXUIElement) -> CGRect? {
      Node(element, batch: [kAXPositionAttribute, kAXSizeAttribute]).frame
    }

    /// How a snapshot lists the node, or nil to leave it out
    /// (`ScreenSnapshot.listedKind`), and what it's called
    /// (`ScreenSnapshot.label`). `bounds`: the window's frame, or the page's
    /// inside it.
    static func describe(
      _ node: Node, in bounds: CGRect?, until deadline: ContinuousClock.Instant? = nil
    ) -> (kind: String, label: String)? {
      guard let role = node.role,
        let kind = ScreenSnapshot.listedKind(
          role: role, subrole: node.string(kAXSubroleAttribute), frame: node.frame, bounds: bounds,
          pressable: { isPressable(node.element) }),
        let label = ScreenSnapshot.label(
          role: role, own: labels(node), placeholder: node.string(kAXPlaceholderValueAttribute),
          borrowed: { borrowedLabel(node) }, inner: { firstText(under: node, until: deadline) })
          // A field with no name of any kind is still somewhere to type.
          ?? (ScreenSnapshot.textEntryRoles.contains(role) ? kind : nil)
      else { return nil }
      return (kind, label)
    }

    static func isPressable(_ element: AXUIElement) -> Bool {
      var names: CFArray?
      guard AXUIElementCopyActionNames(element, &names) == .success else { return false }
      return (names as? [String])?.contains(kAXPressAction) ?? false
    }
  }

  extension AXRead {
    /// One element as a walk sees it: its common attributes fetched in one
    /// round trip (`AXUIElementCopyMultipleAttributeValues`) the first time any
    /// is asked for, rather than a call each, and its children and value kept
    /// once read — so a walk and the row-name lookup inside it share them.
    /// Never `AXValue` in the batch: for a text field that's what the user
    /// typed, so it's read on its own, and only for a role whose value is its
    /// name. One read in one task: not `Sendable`, and it needn't be.
    final class Node {
      let element: AXUIElement
      private let batch: [String]
      /// `batch`, read the first time any of it is asked for.
      private lazy var attributes: [String: CFTypeRef] = Self.read(element, batch)

      init(_ element: AXUIElement, batch: [String] = Node.batch) {
        self.element = element
        self.batch = batch
      }

      /// The attributes one round trip fetches: what `describe`, `names`, a
      /// walk's children, a frame, a scroll area's parent and a menu item's
      /// enabled state read.
      static let batch: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXChildrenAttribute, kAXTitleUIElementAttribute,
        kAXParentAttribute, kAXEnabledAttribute,
      ]

      /// One of `batch`'s attributes, nil when the element doesn't have it.
      func attribute(_ name: String) -> CFTypeRef? { attributes[name] }

      func string(_ name: String) -> String? { (attribute(name) as? String)?.trimmedNonEmpty() }

      func element(_ name: String) -> AXUIElement? {
        attribute(name).flatMap(FocusCapture.axElement).map(AXRead.capped)
      }

      var role: String? { string(kAXRoleAttribute) }

      lazy var children: [Node] = (attribute(kAXChildrenAttribute) as? [AXUIElement] ?? []).map {
        Node(AXRead.capped($0))
      }

      var frame: CGRect? {
        guard
          let position = attribute(kAXPositionAttribute).flatMap({ FocusCapture.axValue($0, .cgPoint, CGPoint.zero) }),
          let size = attribute(kAXSizeAttribute).flatMap({ FocusCapture.axValue($0, .cgSize, CGSize.zero) })
        else { return nil }
        return CGRect(origin: position, size: size)
      }

      /// Its `AXValue`, read once, alone. Asked only for a value-named role
      /// (`nameValue`) or a row's text inside it (`ScreenSnapshot.firstText`):
      /// never a text entry's contents.
      lazy var rawValue: String? = AXRead.string(element, kAXValueAttribute)

      /// Its value when that's its name (`ScreenSnapshot.valueNamedRoles`),
      /// and nil, without the call, for every other role: in a slow app each
      /// read costs ~90 ms, and a text entry's value is what was typed.
      var nameValue: String? {
        guard let role, ScreenSnapshot.valueNamedRoles.contains(role) else { return nil }
        return rawValue
      }

      /// `batch` in one call. An attribute the element doesn't have comes back
      /// as an `AXValue` holding an `AXError`, and is left out.
      private static func read(_ element: AXUIElement, _ batch: [String]) -> [String: CFTypeRef] {
        var values: CFArray?
        guard
          AXUIElementCopyMultipleAttributeValues(
            element, batch as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
          let array = values as? [CFTypeRef]
        else { return [:] }
        var read: [String: CFTypeRef] = [:]
        for (name, value) in zip(batch, array) where FocusCapture.axValue(value, .axError, AXError.success) == nil {
          read[name] = value
        }
        return read
      }
    }
  }
#endif
