#if os(macOS)
  import AppKit
  import Synchronization
  import Testing

  @testable import BlurtEngine

  /// Thread-safe single-value cell for capturing an arbitrary value written inside
  /// a `@Sendable` closure and reading it back after the awaited call returns —
  /// also how a closure holds the handle of the very task executing it, so it can
  /// cancel it (a `Task` is `Sendable`, so that needs no separate box).
  final class ValueBox<T: Sendable>: Sendable {
    private let stored: Mutex<T>
    /// One settable property rather than a `value` getter beside a `set(_:)` — the
    /// `Mutex` is what makes the class `Sendable`, so both accessors can go through
    /// it and callers read as ordinary assignment.
    var value: T {
      get { stored.withLock { $0 } }
      set { stored.withLock { $0 = newValue } }
    }

    init(_ initial: T) { stored = Mutex(initial) }
  }

  extension ValueBox where T == Bool {
    /// A `KeyInjector` `postPaste` double that records the ⌘V was posted and
    /// reports it landed — for a test that asserts on whether the paste happened.
    var recordingPaste: @Sendable (CGKeyCode) -> Bool {
      { _ in
        self.value = true
        return true
      }
    }
  }
#endif
