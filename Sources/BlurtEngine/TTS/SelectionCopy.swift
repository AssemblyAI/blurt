#if os(macOS)
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
  ///
  /// The press waits for the copy, so in such an app every dictation press with
  /// nothing selected starts up to `timeout` late. Starting the recording first
  /// and cancelling it on a hit was tried and rejected: the cancel can land on the
  /// previous dictation's pipeline, and every read would open the mic.
  struct SelectionCopy: Sendable {
    private let pasteboard: any CopyPasteboard
    private let postCopy: @Sendable () -> Bool
    /// How long to wait for the app to answer the ⌘C. Measured copies land in
    /// tens of milliseconds, and nothing landing means nothing was selected. Kept
    /// short because a dictation press pays all of it.
    private let timeout: Duration
    /// How long after `timeout` a late answer to the ⌘C is still watched for,
    /// so the user's clipboard is put back even when the app copied too slowly
    /// to be read (a busy app can take past `timeout`). The press doesn't wait
    /// for this; it runs behind it.
    private let lateCopyWindow: Duration

    init(
      pasteboard: any CopyPasteboard = SystemClipboard(),
      postCopy: @escaping @Sendable () -> Bool = { KeyInjector.postCmdC() },
      timeout: Duration = .milliseconds(100),
      lateCopyWindow: Duration = .seconds(1)
    ) {
      self.pasteboard = pasteboard
      self.postCopy = postCopy
      self.timeout = timeout
      self.lateCopyWindow = lateCopyWindow
    }

    /// The copied text, up to `maxCharacters`, or nil when the copy produced
    /// nothing readable. The clipboard is restored whenever the copy changed it.
    func copySelection(maxCharacters: Int) async -> String? {
      let pasteboard = pasteboard
      // An unreadable pasteboard can't be restored, so don't disturb it.
      let (saved, before) = await BlockingIPC.run { (pasteboard.snapshot(), pasteboard.changeCount) }
      guard let saved, postCopy() else { return nil }
      let deadline = ContinuousClock.now + timeout
      // Wait for a string, not just a change: an app may clear the clipboard and
      // write it a moment later, and the clear alone moves the change count.
      var seen = before
      var copied: String?
      repeat {
        try? await Task.sleep(for: .milliseconds(10))
        (seen, copied) = await BlockingIPC.run {
          let count = pasteboard.changeCount
          guard count != before else { return (count, nil) }
          let string = pasteboard.currentString()
          // A write between the two reads would pair the string with a stale
          // count, and the restore would then skip. Poll again instead.
          return pasteboard.changeCount == count ? (count, string) : (count, nil)
        }
      } while copied == nil && ContinuousClock.now < deadline
      let copyCount = seen
      let settled = await BlockingIPC.run {
        if copyCount != before { pasteboard.restore(saved, ifChangeCountIs: copyCount) }
        return pasteboard.changeCount
      }
      // Nothing readable in time, but the app may still answer. Nothing else
      // would put the user's clipboard back then.
      if copied == nil { restoreLateCopy(saved, after: settled) }
      // The same cleanup as the AX read, so a zero-width-only copy isn't spoken.
      return FocusCapture.visibleTextOrNil(FocusCapture.clip(copied?.trimmedNonEmpty(), to: maxCharacters))
    }

    /// Restores `saved` over the first change after `baseline`, if one comes
    /// within `lateCopyWindow`: the ⌘C's answer arriving after the press gave up
    /// on it.
    private func restoreLateCopy(_ saved: PasteboardSnapshot, after baseline: Int) {
      let pasteboard = pasteboard
      let deadline = ContinuousClock.now + lateCopyWindow
      Task {
        while ContinuousClock.now < deadline {
          try? await Task.sleep(for: .milliseconds(20))
          let restored = await BlockingIPC.run { () -> Bool in
            let count = pasteboard.changeCount
            guard count != baseline else { return false }
            pasteboard.restore(saved, ifChangeCountIs: count)
            return true
          }
          if restored { return }
        }
      }
    }
  }

  /// The pasteboard operations `SelectionCopy` needs, so tests never touch the real
  /// clipboard. `SystemClipboard` is the production conformance.
  protocol CopyPasteboard: Sendable {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot?
    func currentString() -> String?
    func restore(_ saved: PasteboardSnapshot, ifChangeCountIs expected: Int)
  }
#endif
