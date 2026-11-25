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

  var calls: [Call] { recorded.withLock { $0 } }

  init(steps: [VoiceCommandStep] = [], error: (any Error & Sendable)? = nil, hangs: Bool = false) {
    self.steps = steps
    self.error = error
    self.hangs = hangs
  }

  func plan(_ command: String, context: ScreenContext, trace _: PlanTrace) async throws -> [VoiceCommandStep] {
    recorded.withLock { $0.append(Call(command: command, context: context)) }
    if hangs { try await Task.sleep(for: .seconds(60)) }
    if let error { throw error }
    return steps
  }
}
