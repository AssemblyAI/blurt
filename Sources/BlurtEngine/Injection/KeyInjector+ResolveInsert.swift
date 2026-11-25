#if os(macOS)
  import Foundation

  // The paste's continuity decision, apart from the actor's orchestration
  // (`KeyInjector.swift`): a pure function with no actor state.
  extension KeyInjector {
    /// Both of `performInsert`'s continuity decisions, as one pure function taking
    /// the paste target as a plain pid rather than an `NSRunningApplication`:
    /// which text to write, and which window to remember writing it into.
    ///
    /// A pid is all the decision ever needed. Computed inline in `performInsert`,
    /// it could only be reached through a full `insert`, so its four cases were
    /// covered by scraping `NSWorkspace` for live processes — one case required
    /// the host to be running two — which activated the developer's foreground app
    /// and failed whenever the unordered pick landed on a background-only process.
    /// Here the same cases are plain values, and `insert` keeps one end-to-end test
    /// for the wiring.
    static func resolveInsert(
      text: String,
      priorText: String?,
      windowTitle: String?,
      targetPID: pid_t?,
      lastInserted: ResolvedInsert?
    ) -> ResolvedInsert {
      let currentWindow = targetPID.flatMap { pid in
        windowTitle.map { WindowIdentity(pid: pid, title: $0) }
      }
      // `currentWindow.map { ... } ?? false` rather than `currentWindow == lastInserted?.window`:
      // both sides being nil (nothing readable this time, nothing pasted last time)
      // must not count as a match.
      let sameWindow = currentWindow.map { $0 == lastInserted?.window } ?? false
      let basis = InsertionSeparator.basis(
        priorText: priorText, lastInserted: lastInserted?.text, sameWindow: sameWindow
      )
      return ResolvedInsert(text: InsertionSeparator.withLeadingSeparator(text, after: basis), window: currentWindow)
    }
  }
#endif
