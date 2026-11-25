#if os(macOS)
  import AppKit
  import Synchronization
  import Testing

  @testable import BlurtEngine

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
          if s.opened {
            return true
          }
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
#endif
