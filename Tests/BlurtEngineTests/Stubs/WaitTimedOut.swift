/// What `waitUntil(_:timeout:_:)` throws when its condition never held: names
/// what the test was waiting for, so a hang reads as the thing that never
/// happened.
struct WaitTimedOut: Error, CustomStringConvertible {
  let awaited: String
  let timeout: Duration

  var description: String { "timed out after \(timeout) waiting for \(awaited)" }
}
