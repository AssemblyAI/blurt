import BlurtEngine
import BlurtiOSCore

// MARK: - The phase, written for the keyboard
//
// What the keyboard reads: the phase with the press it answers and the
// dictation it names, written to the App Group and signalled.

extension DictationCoordinator {
  /// Why the phase is an error, typed, for the keyboard's line: a capture
  /// failure's reason; nothing for a failure the engine words itself.
  func reason(for phase: PipelinePhase) -> FailureReason? {
    guard case .failed(.audioCaptureFailed(let underlying)) = phase else {
      return nil
    }
    return CaptureFailure.reason(for: underlying)
  }

  func publish(_ state: OverlayUIState, reason: FailureReason? = nil) {
    let snapshot = PhaseSnapshot(
      state: PhaseSnapshot.State(state),
      message: PhaseSnapshot.message(for: state),
      level: Double(level),
      at: now(),
      command: lastCommandID,
      reason: reason,
      answers: answers,
      dictation: inFlight,
      launchID: window.launchID,
      recordingSince: recordingSince
    )
    store.write(snapshot, forKey: BlurtShared.Key.phase)
    store.post(BlurtShared.Signal.phase)
  }
}
