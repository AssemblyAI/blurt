import Synchronization

@testable import BlurtEngine

/// A performer that records each step it carried out, or throws `error` on the first.
final class StubPerformer: VoiceCommandPerforming {
  private let screen: ScreenContext
  private let error: (any Error & Sendable)?
  /// Which step `error` is thrown at, by index; every step when nil.
  private let failingAt: Int?
  private let recorded = Mutex<[VoiceCommandStep]>([])
  private let lifecycle = Mutex<[String]>([])
  private let reads = Mutex(0)

  var performed: [VoiceCommandStep] { recorded.withLock { $0 } }
  /// "starting" and "ended", in the order the router called them.
  var events: [String] { lifecycle.withLock { $0 } }

  /// How many times the screen was read.
  var screenReads: Int { reads.withLock { $0 } }

  init(
    screen: ScreenContext = ScreenContext(appName: nil), error: (any Error & Sendable)? = nil, failingAt: Int? = nil
  ) {
    self.screen = screen
    self.error = error
    self.failingAt = failingAt
  }

  /// No beat between steps: the stub acts synchronously.
  var settle: Duration { .zero }

  func commandStarting() { lifecycle.withLock { $0.append("starting") } }
  func commandEnded() { lifecycle.withLock { $0.append("ended") } }

  func screenContext() -> ScreenContext {
    reads.withLock { $0 += 1 }
    return screen
  }

  func perform(_ step: VoiceCommandStep) throws -> String? {
    if let error, failingAt == nil || failingAt == performed.count { throw error }
    recorded.withLock { $0.append(step) }
    return "stubbed"
  }
}
