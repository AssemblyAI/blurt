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
      AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
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
    static func pressButton(_ name: String) async throws {
      guard let app = await frontmostElement(),
        let window = AXRead.element(app, kAXFocusedWindowAttribute) ?? AXRead.element(app, kAXMainWindowAttribute),
        let target = ElementSearch.best(
          named: name, from: window, children: AXRead.children, labels: AXRead.labels, pressable: AXRead.isPressable)
      else { throw VoiceCommandError.buttonNotFound(name) }
      guard !AXRead.labels(target).contains(where: DestructiveGuard.isDestructive(label:)) else {
        throw VoiceCommandError.refused("press \(name)")
      }
      try await press(ElementSnapshot.Handle(element: target), pid: pid(of: app))
    }

    /// Chooses the frontmost app's menu item at `path`, from the menu-bar
    /// title down (Hammerspoon's `selectMenuItem`, MIT): an item is pressed
    /// without its menu being opened, so nothing flashes on screen.
    static func chooseMenuItem(_ path: [String]) async throws {
      guard let app = await frontmostElement(), var item = AXRead.element(app, kAXMenuBarAttribute) else {
        throw VoiceCommandError.menuItemNotFound(path)
      }
      for title in path {
        // A bar item's or a submenu item's entries sit inside its one AXMenu child.
        let entries = AXRead.children(item).flatMap {
          AXRead.string($0, kAXRoleAttribute) == kAXMenuRole ? AXRead.children($0) : [$0]
        }
        let titled = entries.compactMap { entry in
          AXRead.string(entry, kAXTitleAttribute).map { (title: $0, entry: entry) }
        }
        guard let match = NameMatch.best(for: title, among: titled.map(\.title)),
          let next = titled.first(where: { $0.title == match })?.entry
        else { throw VoiceCommandError.menuItemNotFound(path) }
        guard !DestructiveGuard.isDestructive(label: match) else {
          throw VoiceCommandError.refused("choose \(path.joined(separator: " › "))")
        }
        item = next
      }
      // A dimmed item is one the app would ignore: say so rather than "Done".
      guard AXRead.bool(item, kAXEnabledAttribute) != false,
        AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
      else { throw VoiceCommandError.couldNotPerform("choose \(path.joined(separator: " › "))") }
    }

    static func pid(of element: AXUIElement) -> pid_t? {
      var pid: pid_t = 0
      return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    private static func frontmostElement() async -> AXUIElement? {
      guard let pid = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication?.processIdentifier }) else {
        return nil
      }
      return AXUIElementCreateApplication(pid)
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
      guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
      // The type ID was just checked.
      return capped(value as! AXUIElement)  // swiftlint:disable:this force_cast
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
      (value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).map(capped)
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
      (value(element, attribute) as? String)?.trimmedNonEmpty()
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
      value(element, attribute) as? Bool
    }

    /// What a user would call it: its title, else its description (an icon
    /// button's spoken name), else a link's text.
    static func labels(_ element: AXUIElement) -> [String] {
      [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { string(element, $0) }
    }

    /// Its labels, then the names it borrows: the `<label>` a web form
    /// control points at (`AXTitleUIElement`), and the text inside a clickable
    /// `<div>` (its first static-text child's value).
    static func names(_ element: AXUIElement) -> [String] {
      let own = labels(element)
      if !own.isEmpty { return own }
      if let title = self.element(element, kAXTitleUIElementAttribute), let name = labels(title).first {
        return [name]
      }
      return firstText(under: element).map { [$0] } ?? []
    }

    /// The first text a few levels inside `element`: a clickable `<div>`'s
    /// words, or a row's first cell (Music's "Songs", a Finder file's name, a
    /// message's sender). A row's text field counts too — a Finder name cell
    /// is one — since it's the row's name, not something being typed.
    ///
    /// Text before any title, and never an image's: a Music sidebar row's
    /// icon is an `AXImage` described by its symbol's name ("radio", "pin"),
    /// which comes before the row's words.
    private static func firstText(under element: AXUIElement) -> String? {
      var queue = children(element)
      var index = 0
      var title: String?
      while index < queue.count, index < 12 {
        let node = queue[index]
        index += 1
        let role = string(node, kAXRoleAttribute)
        if role == kAXStaticTextRole || role == kAXTextFieldRole, let text = string(node, kAXValueAttribute) {
          return text
        }
        if role != kAXImageRole, title == nil {
          title = string(node, kAXTitleAttribute) ?? string(node, kAXDescriptionAttribute)
        }
        queue += children(node)
      }
      return title
    }

    /// Its frame in global, top-left-origin coordinates — the ones a
    /// `CGEvent` click takes.
    static func frame(_ element: AXUIElement) -> CGRect? {
      guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
        CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
      else { return nil }
      var origin = CGPoint.zero
      var extent = CGSize.zero
      // The type IDs were just checked.
      // swiftlint:disable force_cast
      guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
      else { return nil }
      // swiftlint:enable force_cast
      return CGRect(origin: origin, size: extent)
    }

    /// How a snapshot lists the element, or nil to leave it out: a role the
    /// planner can act on (`ScreenSnapshot.kind`) with a label to call it by.
    /// A text field with no title goes by its placeholder ("Search").
    ///
    /// `bounds`: the window's frame, or the page's inside it. An element
    /// outside it is scrolled out of view, and left out.
    static func describe(_ element: AXUIElement, in bounds: CGRect?) -> (kind: String, label: String)? {
      guard let role = string(element, kAXRoleAttribute) else { return nil }
      let listed = ScreenSnapshot.kind(role: role, subrole: string(element, kAXSubroleAttribute))
      // A web page's clickable `<div>`: listed only when it takes a press.
      guard
        let kind = listed
          ?? (ScreenSnapshot.clickableRoles.contains(role) && isPressable(element) ? "clickable" : nil),
        ScreenSnapshot.isVisible(frame(element), in: bounds)
      else { return nil }
      guard ScreenSnapshot.isTextEntry(kind) else { return names(element).first.map { (kind, $0) } }
      // Never a text entry's value: that's what the user typed, not its name.
      let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute].lazy
        .compactMap { string(element, $0) }.first
      return (kind, label ?? Self.element(element, kAXTitleUIElementAttribute).flatMap { labels($0).first } ?? kind)
    }

    static func isPressable(_ element: AXUIElement) -> Bool {
      var names: CFArray?
      guard AXUIElementCopyActionNames(element, &names) == .success else { return false }
      return (names as? [String])?.contains(kAXPressAction) ?? false
    }
  }
#endif
