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
      // An unreadable pasteboard can't be restored, so don't disturb it. The
      // own-write count is read first: a Blurt write racing this read can then
      // only make the copy give up, never be taken for the app's answer.
      let (ownWrites, saved, before) = await BlockingIPC.run {
        let ownWrites = pasteboard.ownWriteCount
        return (ownWrites, pasteboard.snapshot(), pasteboard.changeCount)
      }
      guard let saved, postCopy() else { return nil }
      let deadline = ContinuousClock.now + timeout
      // Wait for a string, not just a change: an app may clear the clipboard and
      // write it a moment later, and the clear alone moves the change count.
      var seen = before
      var copied: String?
      var blurtWrote = false
      repeat {
        try? await Task.sleep(for: .milliseconds(10))
        (seen, copied, blurtWrote) = await BlockingIPC.run {
          let count = pasteboard.changeCount
          guard count != before else { return (count, nil, false) }
          // After the change count, as in `restoreLateCopy`: a change that is
          // Blurt's own (an earlier dictation's paste) is already counted.
          guard pasteboard.ownWriteCount == ownWrites else { return (count, nil, true) }
          let string = pasteboard.currentString()
          // A write between the two reads would pair the string with a stale
          // count, and the restore would then skip. Poll again instead.
          return pasteboard.changeCount == count ? (count, string, false) : (count, nil, false)
        }
      } while copied == nil && !blurtWrote && ContinuousClock.now < deadline
      // Blurt wrote the clipboard itself: whatever is there is a paste's, not
      // the selection, and its own restore puts the user's clipboard back.
      guard !blurtWrote else { return nil }
      let copyCount = seen
      let (settled, writesAtSettle) = await BlockingIPC.run {
        if copyCount != before { pasteboard.restore(saved, ifChangeCountIs: copyCount) }
        // The counter before the change count, so a Blurt write landing
        // between them is in the baseline the watcher compares against.
        let writes = pasteboard.ownWriteCount
        return (pasteboard.changeCount, writes)
      }
      // Nothing readable in time, but the app may still answer. Nothing else
      // would put the user's clipboard back then.
      if copied == nil { restoreLateCopy(saved, after: settled, ownWrites: writesAtSettle) }
      // The same cleanup as the AX read, so a zero-width-only copy isn't spoken.
      return FocusCapture.visibleTextOrNil(FocusCapture.clip(copied?.trimmedNonEmpty(), to: maxCharacters))
    }

    /// Restores `saved` over the first change after `baseline`, if one comes
    /// within `lateCopyWindow`: the ⌘C's answer arriving after the press gave up
    /// on it. Blurt's own writes are not that answer — the dictation this press
    /// starts can paste inside the window — so the first one ends the watch
    /// without restoring. A copy the user makes themselves inside the window is
    /// indistinguishable from the late answer and is still undone.
    private func restoreLateCopy(_ saved: PasteboardSnapshot, after baseline: Int, ownWrites: Int) {
      let pasteboard = pasteboard
      let deadline = ContinuousClock.now + lateCopyWindow
      Task {
        while ContinuousClock.now < deadline {
          try? await Task.sleep(for: .milliseconds(20))
          let done = await BlockingIPC.run { () -> Bool in
            let count = pasteboard.changeCount
            guard count != baseline else { return false }
            // Read after the change count: Blurt counts a write before making
            // it, so a change that is Blurt's is already counted here.
            guard pasteboard.ownWriteCount == ownWrites else { return true }
            pasteboard.restore(saved, ifChangeCountIs: count)
            return true
          }
          if done { return }
        }
      }
    }
  }

  /// The pasteboard operations `SelectionCopy` needs, so tests never touch the real
  /// clipboard. `SystemClipboard` is the production conformance.
  protocol CopyPasteboard: Sendable {
    var changeCount: Int { get }
    /// How many writes Blurt itself has made to the pasteboard, counted before
    /// each write lands.
    var ownWriteCount: Int { get }
    func snapshot() -> PasteboardSnapshot?
    func currentString() -> String?
    func restore(_ saved: PasteboardSnapshot, ifChangeCountIs expected: Int)
  }
#endif
