import Foundation
import UIKit

@testable import BlurtiOSCore

/// A throwaway App Group for one test: nothing a test writes reaches the real
/// suite the installed app and keyboard share (the engine's own rule about
/// never touching the real Keychain in tests, applied here).
@MainActor
struct ScratchSuite {
  let name: String

  init() {
    name = "test-\(UUID().uuidString)"
    SharedStore.override = UserDefaults(suiteName: name)
  }

  func tearDown() {
    SharedStore.override?.removePersistentDomain(forName: name)
    SharedStore.override = nil
  }
}

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
