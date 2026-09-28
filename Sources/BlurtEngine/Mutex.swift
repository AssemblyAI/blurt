import Foundation

/// Small deployment-target-compatible replacement for `Synchronization.Mutex`.
/// `NSLock` is available throughout VibeDictate's macOS 13+ range.
final class Mutex<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  @discardableResult
  func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }
}
