#if os(macOS)
  import AppKit
  import ApplicationServices
  import CoreGraphics

  // The steps that adjust a listed control or scroll: everything a hand on
  // the trackpad does to an element besides pressing it.
  extension SystemVoiceCommandPerformer {
    static func adjust(_ step: VoiceCommandStep, in snapshot: ElementSnapshot) async throws -> String? {
      let pid = await frontmostPID()
      guard let id = step.elementID else { return nil }
      let handle = try snapshot.element(id, pid: pid)
      let node = AXRead.Node(handle.element)
      switch step {
      case .setValue, .increment, .decrement:
        // A value a control holds, never text a field holds.
        try require(node, roleIn: ScreenSnapshot.adjustableRoles, for: "change", what: "a slider or a stepper")
        try change(node, by: step)
      case .showMenu:
        guard try performAction(kAXShowMenuAction, on: node) == .success else {
          throw VoiceCommandError.couldNotPerform("open that menu")
        }
      case .select:
        try require(node, roleIn: ScreenSnapshot.selectableRoles, for: "select", what: "a row")
        // A row that won't take the attribute (a web list) takes a click.
        if AXUIElementSetAttributeValue(node.element, kAXSelectedAttribute as CFString, kCFBooleanTrue) != .success {
          try await click(node, pid: pid)
          return "click: AXSelected refused"
        }
        return "AXSelected"
      default: break
      }
      return nil
    }

    /// Sets a slider or stepper to a value, or steps it one notch.
    private static func change(_ node: AXRead.Node, by step: VoiceCommandStep) throws {
      if case .setValue(_, let value) = step {
        guard let number = Double(value),
          AXUIElementSetAttributeValue(node.element, kAXValueAttribute as CFString, NSNumber(value: number)) == .success
        else { throw VoiceCommandError.couldNotPerform("set that to \(value)") }
        return
      }
      let action = if case .increment = step { kAXIncrementAction } else { kAXDecrementAction }
      guard try performAction(action, on: node) == .success else { throw VoiceCommandError.elementGone }
    }

    /// A page up, down, left or right: the scroll area holding the listed
    /// element, else the window's largest. Its own page action first, then a
    /// scroll-wheel event over its centre for an area that has none.
    static func scroll(
      _ direction: ScrollDirection, element id: Int?, in snapshot: ElementSnapshot
    ) async throws -> String {
      let pid = await frontmostPID()
      let area: AXUIElement?
      if let id {
        area = scrollArea(around: AXRead.Node(try snapshot.element(id, pid: pid).element))
      } else {
        area = pid.map(AXRead.app).flatMap(AXRead.window).flatMap {
          largest(role: kAXScrollAreaRole, in: AXRead.Node($0))?.element
        }
      }
      guard let area else { throw VoiceCommandError.couldNotPerform("find anything to scroll") }
      if AXUIElementPerformAction(area, direction.pageAction as CFString) == .success { return "page action" }
      guard let frame = AXRead.frame(area),
        let event = CGEvent(
          scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: direction.wheelLines.vertical,
          wheel2: direction.wheelLines.horizontal, wheel3: 0)
      else { throw VoiceCommandError.couldNotPerform("scroll") }
      // A wheel event scrolls what's under the pointer.
      try await withPointer(at: CGPoint(x: frame.midX, y: frame.midY)) { event.post(tap: .cghidEventTap) }
      return "scroll wheel: no page action"
    }

    /// The nearest scroll area at or above `node`: each level's role and
    /// parent in one round trip (`AXRead.Node`), within `ScreenSnapshot.readBudget`.
    private static func scrollArea(around node: AXRead.Node) -> AXUIElement? {
      let deadline = ContinuousClock.now.advanced(by: ScreenSnapshot.readBudget)
      var current: AXRead.Node? = node
      for _ in 0..<40 where ContinuousClock.now < deadline {
        guard let level = current else { return nil }
        if level.role == kAXScrollAreaRole { return level.element }
        current = level.element(kAXParentAttribute).map { AXRead.Node($0) }
      }
      return nil
    }
  }
#endif
