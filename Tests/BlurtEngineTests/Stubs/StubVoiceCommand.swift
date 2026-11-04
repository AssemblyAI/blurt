import Synchronization

@testable import BlurtEngine

/// A planner that records each call and answers with `steps`, or throws
/// `error` — or, `hangs`, plans until cancelled.
final class StubPlanner: VoiceCommandPlanning {
  struct Call: Equatable {
    let command: String
    let context: ScreenContext
  }

  private let steps: [VoiceCommandStep]
  private let error: (any Error & Sendable)?
  private let hangs: Bool
  private let recorded = Mutex<[Call]>([])

  init(steps: [VoiceCommandStep] = [], error: (any Error & Sendable)? = nil, hangs: Bool = false) {
    self.steps = steps
    self.error = error
    self.hangs = hangs
  }

  var calls: [Call] { recorded.withLock { $0 } }

  func plan(_ command: String, context: ScreenContext, trace: PlanTrace) async throws -> [VoiceCommandStep] {
    recorded.withLock { $0.append(Call(command: command, context: context)) }
    if hangs { try await Task.sleep(for: .seconds(60)) }
    if let error { throw error }
    return steps
  }
}

/// A performer that records each step it carried out, or throws `error` on the first.
final class StubPerformer: VoiceCommandPerforming {
  private let screen: ScreenContext
  private let error: (any Error & Sendable)?
  /// Which step `error` is thrown at, by index; every step when nil.
  private let failingAt: Int?
  private let recorded = Mutex<[VoiceCommandStep]>([])
  private let lifecycle = Mutex<[String]>([])
  private let reads = Mutex(0)

  init(
    screen: ScreenContext = ScreenContext(appName: nil), error: (any Error & Sendable)? = nil, failingAt: Int? = nil
  ) {
    self.screen = screen
    self.error = error
    self.failingAt = failingAt
  }

  var performed: [VoiceCommandStep] { recorded.withLock { $0 } }
  /// "starting" and "ended", in the order the router called them.
  var events: [String] { lifecycle.withLock { $0 } }

  func commandStarting() async { lifecycle.withLock { $0.append("starting") } }
  func commandEnded() async { lifecycle.withLock { $0.append("ended") } }

  /// How many times the screen was read.
  var screenReads: Int { reads.withLock { $0 } }

  func screenContext() async -> ScreenContext {
    reads.withLock { $0 += 1 }
    return screen
  }

  func perform(_ step: VoiceCommandStep) async throws -> String? {
    if let error, failingAt == nil || failingAt == performed.count { throw error }
    recorded.withLock { $0.append(step) }
    return "stubbed"
  }
}
