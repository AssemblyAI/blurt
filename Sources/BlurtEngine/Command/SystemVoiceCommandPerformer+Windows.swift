#if os(macOS)
  import AppKit
  import ApplicationServices
  import CoreGraphics

  // A `window` step: the frontmost app's focused window moved, resized,
  // minimized or made full screen through its Accessibility attributes — the
  // same ones Rectangle and Hammerspoon set. Where it goes is `WindowLayout`.
  extension SystemVoiceCommandPerformer {
    static func arrangeWindow(_ operation: WindowOperation) async throws -> String? {
      guard let window = await frontmostApp().flatMap(AXRead.window)
      else { throw VoiceCommandError.couldNotPerform("find a window to arrange") }
      switch operation {
      case .minimize: try set(window, kAXMinimizedAttribute, kCFBooleanTrue)
      case .fullScreen: try set(window, "AXFullScreen", kCFBooleanTrue)
      default: return try await move(window, operation)
      }
      return nil
    }

    /// A window that can't be resized (Calculator) is moved to where the
    /// arrangement puts it, keeping its size, and says so.
    private static func move(_ window: AXUIElement, _ operation: WindowOperation) async throws -> String? {
      guard let frame = AXRead.frame(window) else { throw VoiceCommandError.couldNotPerform("read the window") }
      let displays = await MainActor.run { () -> [CGRect] in
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { WindowLayout.accessibilityFrame($0.visibleFrame, primaryHeight: primaryHeight) }
      }
      let centre = CGPoint(x: frame.midX, y: frame.midY)
      let visible = displays.first { $0.contains(centre) } ?? displays.first ?? frame
      let target =
        operation == .nextDisplay
        ? WindowLayout.onNextDisplay(frame, displays: displays)
        : WindowLayout.frame(for: operation, window: frame, visible: visible)
      guard let target else { throw VoiceCommandError.couldNotPerform("move the window there") }
      // Position, size, then position again: an app that clamps a window to
      // its display can refuse the size until the window has moved, and
      // refuse the position until it has shrunk.
      guard isSettable(window, kAXSizeAttribute) else {
        try setFrameOrigin(window, target.origin)
        return "can't be resized: moved only"
      }
      try setFrameOrigin(window, target.origin)
      try setFrameSize(window, target.size)
      try setFrameOrigin(window, target.origin)
      return nil
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
      var settable: DarwinBoolean = false
      return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    private static func setFrameOrigin(_ window: AXUIElement, _ origin: CGPoint) throws {
      var origin = origin
      guard let value = AXValueCreate(.cgPoint, &origin) else {
        throw VoiceCommandError.couldNotPerform("move the window")
      }
      try set(window, kAXPositionAttribute, value)
    }

    private static func setFrameSize(_ window: AXUIElement, _ size: CGSize) throws {
      var size = size
      guard let value = AXValueCreate(.cgSize, &size) else {
        throw VoiceCommandError.couldNotPerform("resize the window")
      }
      try set(window, kAXSizeAttribute, value)
    }

    private static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) throws {
      guard AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success else {
        throw VoiceCommandError.couldNotPerform("arrange the window")
      }
    }
  }
#endif
