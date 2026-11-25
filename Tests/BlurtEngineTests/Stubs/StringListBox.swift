#if os(macOS)
  import AppKit
  import Synchronization
  import Testing

  @testable import BlurtEngine

  /// Thread-safe ordered list of strings recorded inside a `@Sendable` closure,
  /// for asserting the sequence of texts a test observed being pasted. Not a
  /// `ValueBox<[String]>`: the atomic append is the point — appending through a
  /// get-then-set property would race two recorders against each other.
  final class StringListBox: Sendable {
    private let items = Mutex<[String]>([])
    var values: [String] {
      items.withLock { $0 }
    }

    func append(_ value: String?) {
      items.withLock { $0.append(value ?? "") }
    }
  }

  extension StringListBox {
    /// A `DictationSession` `onTranscriptDelivered` double that records each
    /// delivered transcript, for a test that asserts on what was delivered.
    var recordingDelivery: @Sendable (String, RecentDictations) -> Void {
      { text, _ in self.append(text) }
    }
  }
#endif
