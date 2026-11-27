import Foundation

@testable import BlurtiOSCore

/// A phase as the app would publish it, now: `dictation` names the one in
/// flight, `answers` the press it answers.
@MainActor
func snapshot(
  _ state: PhaseSnapshot.State,
  level: Double = 0,
  dictation: UUID? = nil,
  answers: UUID? = nil,
  reason: FailureReason? = nil
) -> PhaseSnapshot {
  PhaseSnapshot(
    state: state,
    message: nil,
    level: level,
    at: Date(),
    reason: reason,
    answers: answers,
    dictation: dictation.map { DictationRef(id: $0, ownerProcessID: KeyboardProcess.id) }
  )
}
