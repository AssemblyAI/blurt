import Foundation
import Security
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// A clock the test moves.
final class SignInTestClock: Sendable {
  let date = Mutex(Date(timeIntervalSince1970: 1_790_000_000))
  var now: Date { date.withLock { $0 } }

  func advance(_ interval: TimeInterval) { date.withLock { $0 += interval } }
}
