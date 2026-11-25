import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// What a job press — a rewrite or a command — told the pill and the gate:
/// shared by the rewrite and command router suites.
@MainActor
final class JobEvents {
  var pills: [OverlayUIState?] = []
  var resets = 0

  /// Records `router`'s job pill and gate resets.
  init(watching router: SelectionSpeechRouter) {
    router.jobPill = { [weak self] in self?.pills.append($0) }
    router.resetGate = { [weak self] in self?.resets += 1 }
  }

  /// What the pill showed after the job's working state (`first`), once the
  /// job has ended; stops `phases` either way.
  func outcomes(after first: OverlayUIState, stopping phases: Task<Void, Never>) async throws -> [OverlayUIState?] {
    defer { phases.cancel() }
    try await waitUntil { self.pills.count > 1 }
    #expect(pills.first == first)
    return Array(pills.dropFirst())
  }
}
