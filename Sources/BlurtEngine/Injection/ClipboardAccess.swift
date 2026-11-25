#if os(macOS)
  /// The two clipboard operations `KeyInjector` actually performs around a paste —
  /// a plain overwrite, or an overwrite that can later restore what it displaced —
  /// rather than exposing NSPasteboard's raw change-count/multi-item bookkeeping.
  /// A seam so tests substitute a trivial in-memory fake that never has to
  /// re-derive the pasteboard's change-count semantics to stay faithful.
  protocol ClipboardAccess: Sendable {
    /// Serializes a paste against Blurt's other turns on this pasteboard
    /// (`SelectionCopy`'s copy) — see `PasteboardLock`.
    var lock: PasteboardLock { get }

    /// Overwrite the clipboard with a single plain-string item, discarding the
    /// previous contents. The degraded paste paths call this to leave the
    /// transcript on the clipboard for a manual paste. `concealed` is a
    /// dictation into a password field: its words are a secret, so they are
    /// left marked as one and only for a while (`SystemClipboard`).
    func write(_ text: String, concealed: Bool)
    /// Overwrite the clipboard with `text`, returning an action that restores the
    /// previous contents — but only if nothing else has written to the clipboard
    /// in the meantime (so a user copy during the paste-settle window survives).
    /// Call the returned action once the paste has settled. `concealed` as above.
    func writeAndPrepareRestore(_ text: String, concealed: Bool) -> @Sendable () -> Void
  }
#endif
