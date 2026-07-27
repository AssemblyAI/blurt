import AppKit
import ApplicationServices
import CoreGraphics

// The system side effects behind `KeyInjector`'s injectable seams: the default
// implementations of app activation, the frontmost-wait, the Accessibility-trust
// check, and the synthesized ⌘V. Split out from the actor's paste orchestration
// (`KeyInjector.swift`) because these are pure AppKit/CoreGraphics glue with no
// actor state — the only place `KeyInjector` needs CoreGraphics or
// ApplicationServices at all. `static`, not `private`, so the initializers in
// `KeyInjector.swift` can wire them as the defaults across the file boundary.
extension KeyInjector {
  static func activate(_ app: NSRunningApplication) -> Bool {
    app.activate()
  }

  static func waitUntilFrontmost(_ app: NSRunningApplication) async -> Bool {
    let pid = app.processIdentifier
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(350))
    while clock.now < deadline {
      if await isFrontmost(pid) { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    // One last read: the final sleep may have carried us past the deadline just
    // before the activation landed.
    return await isFrontmost(pid)
  }

  /// Whether `pid` owns the frontmost application right now. Named rather than
  /// inlined so the poll and the post-deadline check share one expression — and so
  /// neither needs `MainActor.run`'s explicit `body:` label, which a trailing
  /// closure in an `if` condition can't use.
  private static func isFrontmost(_ pid: pid_t) async -> Bool {
    await MainActor.run {
      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }
  }

  static func accessibilityTrusted() -> Bool {
    AXIsProcessTrusted()
  }

  /// Posts Cmd-V. Returns `false` if the events couldn't be built. The real side
  /// effect (a keystroke into the focused app) is why this is the injectable seam
  /// tests replace.
  static func postCmdV() -> Bool {
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
