import AppKit
import Foundation
import Testing

/// Shared fixtures for the `KeyInjector.insert` suites (the main insert suite
/// and the fallback/cancel suite live in separate files to stay within the
/// lint file-length budget, but drive the injector the same way).

/// Some live application to stand in as the captured paste target.
func liveTargetApp() throws -> NSRunningApplication {
  try #require(
    NSWorkspace.shared.runningApplications.first {
      $0.processIdentifier > 0 && !$0.isTerminated
    })
}

/// One-shot async gate: `wait()` suspends until `open()` is called. Tolerates
/// `open()` racing ahead of `wait()` (the waiter then returns immediately).
final class AsyncGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var opened = false

  func wait() async {
    await withCheckedContinuation { cont in
      lock.lock()
      if opened {
        lock.unlock()
        cont.resume()
      } else {
        continuation = cont
        lock.unlock()
      }
    }
  }

  func open() {
    lock.lock()
    opened = true
    let cont = continuation
    continuation = nil
    lock.unlock()
    cont?.resume()
  }
}

/// Thread-safe ordered list of strings recorded inside a `@Sendable` closure,
/// for asserting the sequence of texts a test observed being pasted.
final class StringListBox: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  func append(_ value: String?) {
    lock.lock()
    items.append(value ?? "")
    lock.unlock()
  }
  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return items
  }
}

/// Thread-safe boolean flag for assertions inside a `@Sendable` closure.
final class BoolBox: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  func set() {
    lock.lock()
    flag = true
    lock.unlock()
  }
  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return flag
  }
}

/// Thread-safe mutable boolean for injected closures whose answer must change
/// mid-test (e.g. "nothing editable" on the first insert, editable on the next).
final class MutableBoolBox: @unchecked Sendable {
  private let lock = NSLock()
  private var flag: Bool
  init(_ initial: Bool) { flag = initial }
  func set(_ value: Bool) {
    lock.lock()
    flag = value
    lock.unlock()
  }
  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return flag
  }
}

/// Thread-safe holder for a task handle, so a `@Sendable` closure can cancel
/// the very task that is executing it.
final class TaskBox: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, any Error>?
  func set(_ task: Task<Void, any Error>) {
    lock.lock()
    self.task = task
    lock.unlock()
  }
  func cancel() {
    lock.lock()
    let held = task
    lock.unlock()
    held?.cancel()
  }
}
