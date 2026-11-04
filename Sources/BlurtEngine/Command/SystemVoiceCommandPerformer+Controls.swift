#if os(macOS)
  import AppKit
  import ApplicationServices
  import CoreGraphics

  // The steps that adjust a listed control or scroll: everything a hand on
  // the trackpad does to an element besides pressing it.
  extension SystemVoiceCommandPerformer {
    /// The roles a `set_value`, `increment` or `decrement` step may change:
    /// a value a control holds, never text a field holds.
    static let adjustableRoles: Set<String> = ["AXSlider", "AXIncrementor", "AXValueIndicator"]

    static func adjust(_ step: VoiceCommandStep, in snapshot: ElementSnapshot) async throws {
      let pid = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication?.processIdentifier })
      guard let id = step.elementID else { return }
      let handle = try snapshot.element(id, pid: pid)
      let element = handle.element
      switch step {
      case .setValue(_, let value):
        try requireAdjustable(element)
        guard let number = Double(value),
          AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, NSNumber(value: number)) == .success
        else { throw VoiceCommandError.couldNotPerform("set that to \(value)") }
      case .increment, .decrement:
        try requireAdjustable(element)
        let action = step == .increment(id) ? kAXIncrementAction : kAXDecrementAction
        guard AXUIElementPerformAction(element, action as CFString) == .success else {
          throw VoiceCommandError.elementGone
        }
      case .showMenu:
        guard AXUIElementPerformAction(element, kAXShowMenuAction as CFString) == .success else {
          throw VoiceCommandError.couldNotPerform("open that menu")
        }
      case .select:
        try require(element, roleIn: selectableRoles, for: "select")
        // A row that won't take the attribute (a web list) takes a click.
        if AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue) != .success {
          try await click(handle, pid: pid)
        }
      default: break
      }
    }

    private static func requireAdjustable(_ element: AXUIElement) throws {
      guard let role = AXRead.string(element, kAXRoleAttribute), adjustableRoles.contains(role) else {
        throw VoiceCommandError.couldNotPerform("change that: it isn't a slider or a stepper")
      }
    }

    /// A page up, down, left or right: the scroll area holding the listed
    /// element, else the window's largest. Its own page action first, then a
    /// scroll-wheel event over its centre for an area that has none.
    static func scroll(_ direction: ScrollDirection, element id: Int?, in snapshot: ElementSnapshot) async throws {
      let pid = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication?.processIdentifier })
      let area: AXUIElement?
      if let id {
        area = scrollArea(around: try snapshot.element(id, pid: pid).element)
      } else {
        area = pid.flatMap { AXRead.element(AXUIElementCreateApplication($0), kAXFocusedWindowAttribute) }
          .flatMap(largestScrollArea)
      }
      guard let area else { throw VoiceCommandError.couldNotPerform("find anything to scroll") }
      if AXUIElementPerformAction(area, direction.pageAction as CFString) == .success { return }
      guard let frame = AXRead.frame(area),
        let event = CGEvent(
          scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: direction.wheelLines.vertical,
          wheel2: direction.wheelLines.horizontal, wheel3: 0)
      else { throw VoiceCommandError.couldNotPerform("scroll") }
      // A wheel event scrolls what's under the pointer: put it there, then back.
      let home = CGEvent(source: nil)?.location
      CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
      event.post(tap: .cghidEventTap)
      try await Task.sleep(for: .milliseconds(50))
      if let home { CGWarpMouseCursorPosition(home) }
    }

    /// The nearest scroll area at or above `element`.
    private static func scrollArea(around element: AXUIElement) -> AXUIElement? {
      var node: AXUIElement? = element
      for _ in 0..<40 {
        guard let current = node else { return nil }
        if AXRead.string(current, kAXRoleAttribute) == kAXScrollAreaRole { return current }
        node = AXRead.element(current, kAXParentAttribute)
      }
      return nil
    }

    /// The window's largest scroll area: the page, the message list, the
    /// document — rarely a sidebar.
    private static func largestScrollArea(in window: AXUIElement) -> AXUIElement? {
      var best: (area: AXUIElement, size: CGFloat)?
      _ = ScreenSnapshot.entries(
        from: window, children: AXRead.children,
        describe: { node in
          if AXRead.string(node, kAXRoleAttribute) == kAXScrollAreaRole, let frame = AXRead.frame(node),
            frame.width * frame.height > best?.size ?? 0
          {
            best = (node, frame.width * frame.height)
          }
          return nil
        }, visitLimit: 600)
      return best?.area
    }
  }
#endif
