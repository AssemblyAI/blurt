#if os(macOS)
  import AppKit

  /// A thread-safe, value-type representation of a pasteboard item containing its data
  /// keyed by pasteboard types, allowing it to cross concurrency boundaries safely.
  struct SendablePasteboardItem: Sendable {
    let dataMap: [NSPasteboard.PasteboardType: Data]
  }
#endif
