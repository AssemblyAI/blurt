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
/// restore) into the returned box. Shared by the separator-fallback tests,
/// which differ only in the target app(s)/`windowTitle`(s) they drive it with.
func makeRecordingInjector() -> (injector: KeyInjector, pasted: StringListBox) {
  let clip = FakeClipboard(string: nil)
  let pasted = StringListBox()
  let injector = KeyInjector(
    pasteSettleDuration: .zero,
    postPaste: {
      pasted.append(clip.string)
      return true
    },
    clipboard: clip)
  return (injector, pasted)
}

/// One-shot async gate: `wait()` suspends until `open()` is called. Tolerates
/// `open()` racing ahead of `wait()` (the waiter then returns immediately).
final class AsyncGate: Sendable {
  private struct State {
    var continuation: CheckedContinuation<Void, Never>?
    var opened = false
  }
  private let state = Mutex(State())

  func wait() async {
    await withCheckedContinuation { cont in
      let openedAlready = state.withLock { s -> Bool in
        if s.opened { return true }
        s.continuation = cont
        return false
      }
      if openedAlready { cont.resume() }
    }
  }

  func open() {
    let cont = state.withLock { s -> CheckedContinuation<Void, Never>? in
      s.opened = true
      let waiter = s.continuation
      s.continuation = nil
      return waiter
    }
    cont?.resume()
  }
}

/// Thread-safe ordered list of strings recorded inside a `@Sendable` closure,
/// for asserting the sequence of texts a test observed being pasted.
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
/// a `@Sendable` closure and reading it back after the awaited call returns.
final class ValueBox<T: Sendable>: Sendable {
  private let stored: Mutex<T>
  init(_ initial: T) { stored = Mutex(initial) }
  func set(_ value: T) {
    stored.withLock { $0 = value }
  }
  var value: T {
    stored.withLock { $0 }
  }
}

/// Thread-safe holder for a task handle, so a `@Sendable` closure can cancel
/// the very task that is executing it.
final class TaskBox: Sendable {
  private let task = Mutex<Task<Void, any Error>?>(nil)
  func set(_ newTask: Task<Void, any Error>) {
    task.withLock { $0 = newTask }
  }
  func cancel() {
    let held = task.withLock { $0 }
    held?.cancel()
  }
}
