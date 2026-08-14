#if os(macOS)
  import AppKit
  import Synchronization
  import Testing

  @testable import BlurtEngine

  /// Shared fixtures for the `KeyInjector.insert` suites (the main insert suite
  /// and the fallback/cancel suite live in separate files to stay within the
  /// lint file-length budget, but drive the injector the same way).
  ///
  /// The boxes are classes over `Mutex` (not actors) because they're poked from
  /// synchronous `@Sendable` seams like `postPaste`; the `Mutex` makes each
  /// `Sendable` conformance compiler-checked instead of `@unchecked`-asserted.

  /// Some live application to stand in as the captured paste target.
  func liveTargetApp() throws -> NSRunningApplication {
    try #require(
      NSWorkspace.shared.runningApplications.first {
        $0.processIdentifier > 0 && !$0.isTerminated
      })
  }

  /// A `KeyInjector` wired to an in-memory clipboard, with `postPaste` recording
  /// each pasted string (captured after `setString`, before the deferred
  /// restore) into the returned box — for the end-to-end case that pins `insert`
  /// threading its resolution through to the paste. (The continuity rules
  /// themselves are cases of `resolveInsert` and need no injector at all.)
  func makeRecordingInjector() -> (injector: KeyInjector, pasted: StringListBox) {
    let clip = FakeClipboard(string: nil)
    let pasted = StringListBox()
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        pasted.append(clip.string)
        return true
      },
      // Stub the activation. Omitting this defaulted to `KeyInjector.activate`, a
      // REAL `NSRunningApplication.activate()` — so this test yanked the
      // developer's foreground app, and failed spuriously whenever
      // `liveTargetApp()`'s unordered pick landed on a background-only process
      // whose activate() returns false (the injector then throws `.targetAppLost`
      // for reasons unrelated to separator logic). It needs a stable non-nil app
      // identity, not activation.
      activateTarget: { _ in true },
      clipboard: clip)
    return (injector, pasted)
  }

  /// One-shot async gate: `wait()` suspends until `open()` is called. Tolerates
  /// `open()` racing ahead of `wait()` (the waiter then returns immediately), and
  /// any number of concurrent waiters — `Gate`, which is built from a pair of
  /// these, needs that for the stubs whose blocked method is called twice by the
  /// regression under test.
  ///
  /// `open()` is synchronous (a `Mutex`-guarded class, not an actor) because the
  /// seams that trip these gates are synchronous `@Sendable` closures like
  /// `KeyInjector.postPaste`.
  final class AsyncGate: Sendable {
    private struct State {
      var waiters: [CheckedContinuation<Void, Never>] = []
      var opened = false
    }
    private let state = Mutex(State())

    func wait() async {
      await withCheckedContinuation { cont in
        let openedAlready = state.withLock { s -> Bool in
          if s.opened { return true }
          s.waiters.append(cont)
          return false
        }
        if openedAlready { cont.resume() }
      }
    }

    func open() {
      let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
        s.opened = true
        let pending = s.waiters
        s.waiters.removeAll()
        return pending
      }
      for waiter in waiters { waiter.resume() }
    }
  }

  /// Thread-safe ordered list of strings recorded inside a `@Sendable` closure,
  /// for asserting the sequence of texts a test observed being pasted. Not a
  /// `ValueBox<[String]>`: the atomic append is the point — appending through a
  /// get-then-set property would race two recorders against each other.
  final class StringListBox: Sendable {
    private let items = Mutex<[String]>([])
    func append(_ value: String?) {
      items.withLock { $0.append(value ?? "") }
    }
    var values: [String] {
      items.withLock { $0 }
    }
  }

  /// Thread-safe single-value cell for capturing an arbitrary value written inside
  /// a `@Sendable` closure and reading it back after the awaited call returns —
  /// also how a closure holds the handle of the very task executing it, so it can
  /// cancel it (a `Task` is `Sendable`, so that needs no separate box).
  final class ValueBox<T: Sendable>: Sendable {
    private let stored: Mutex<T>
    init(_ initial: T) { stored = Mutex(initial) }
    /// One settable property rather than a `value` getter beside a `set(_:)` — the
    /// `Mutex` is what makes the class `Sendable`, so both accessors can go through
    /// it and callers read as ordinary assignment.
    var value: T {
      get { stored.withLock { $0 } }
      set { stored.withLock { $0 = newValue } }
    }
  }
#endif
