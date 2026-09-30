/// The read-aloud press's fallback for apps whose selection Accessibility can't
/// see. It sends ⌘C, reads what landed on the clipboard, and puts the user's
/// clipboard back.
///
/// Measured against Claude.app (Electron) on 2026-09-30: the system-wide focus
/// query fails with `cannotComplete`, the app-level one has no value, and the web
/// area exposes no selected text, even with `AXManualAccessibility` or
/// `AXEnhancedUserInterface` set. ⌘C copied the highlighted reply text on the
/// first try.
///
/// Runs only when the AX read was `.unreadable`, never when AX saw a bare caret.
/// Some editors copy the whole current line on a ⌘C with no selection, and a
/// fallback on every empty selection would turn an ordinary dictation press into
/// reading that line aloud. An app that is unreadable to AX *and* copies lines
/// (VS Code with accessibility off) still has that problem. It's accepted while
/// the feature is experimental.
struct SelectionCopy: Sendable {
  private let pasteboard: any CopyPasteboard
  private let postCopy: @Sendable () -> Bool
  /// How long to wait for the app to answer the ⌘C. Measured copies land in
  /// tens of milliseconds, and nothing landing means nothing was selected.
  private let timeout: Duration

  init(
    pasteboard: any CopyPasteboard = SystemClipboard(),
    postCopy: @escaping @Sendable () -> Bool = { KeyInjector.postCmdC() },
    timeout: Duration = .milliseconds(250)
  ) {
    self.pasteboard = pasteboard
    self.postCopy = postCopy
    self.timeout = timeout
  }

  /// The copied text, up to `maxCharacters`, or nil when the copy produced
  /// nothing readable. The clipboard is restored whenever the copy changed it.
  func copySelection(maxCharacters: Int) async -> String? {
    // An unreadable pasteboard can't be restored, so don't disturb it.
    guard let saved = pasteboard.snapshot() else { return nil }
    let before = pasteboard.changeCount
    guard postCopy() else { return nil }
    let deadline = ContinuousClock.now + timeout
    while pasteboard.changeCount == before, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    let copiedCount = pasteboard.changeCount
    guard copiedCount != before else { return nil }
    let copied = pasteboard.currentString()
    // Put the user's clipboard back, unless something wrote to it after the copy
    // did. The same rule the paste path's restore follows.
    if pasteboard.changeCount == copiedCount { pasteboard.restore(saved) }
    return copied?.trimmedNonEmpty().map { String($0.prefix(maxCharacters)) }
  }
}

/// The pasteboard operations `SelectionCopy` needs, so tests never touch the real
/// clipboard. `SystemClipboard` is the production conformance.
protocol CopyPasteboard: Sendable {
  var changeCount: Int { get }
  func snapshot() -> PasteboardSnapshot?
  func currentString() -> String?
  func restore(_ saved: PasteboardSnapshot)
}
