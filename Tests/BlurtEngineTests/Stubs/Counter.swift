import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// Thread-safe call counter for asserting how many requests a client issued.
final class Counter: Sendable {
  private let count = Mutex(0)
  var value: Int {
    count.withLock { $0 }
  }

  func next() -> Int {
    count.withLock { value in
      value += 1
      return value
    }
  }
}
