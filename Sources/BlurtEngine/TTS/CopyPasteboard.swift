#if os(macOS)
  /// The pasteboard operations `SelectionCopy` needs, so tests never touch the real
  /// clipboard. `SystemClipboard` is the production conformance.
  protocol CopyPasteboard: Sendable {
    var changeCount: Int { get }
    /// How many writes Blurt itself has made to the pasteboard, counted before
    /// each write lands.
    var ownWriteCount: Int { get }
    /// Serializes the copy against Blurt's paste on this pasteboard — see
    /// `PasteboardLock`.
    var lock: PasteboardLock { get }

    func snapshot() -> PasteboardSnapshot?
    func currentString() -> String?
    func restore(_ saved: PasteboardSnapshot, ifChangeCountIs expected: Int)
  }
#endif
