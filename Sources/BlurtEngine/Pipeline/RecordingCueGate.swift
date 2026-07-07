/// Which record cue chime a pipeline-phase change should fire, if any. A pure
/// projection of `PipelinePhase` transitions — owned here (rather than in the
/// AppKit `CueSoundPlayer`) so the edge logic is unit-testable, the same split
/// as `OverlayUIState` and `MenuBarStatus`. The AppKit side just plays whichever
/// sound this resolves to.
public enum RecordingCue: Equatable, Sendable {
  case start
  case stop
}

/// Edge-detector deciding when the record start/stop chimes fire. The host calls
/// `cue(for:)` on *every* pipeline phase, so the gate fires `.start` only on the
/// idle→recording edge and `.stop` only on the recording→not-recording edge,
/// staying silent while a phase repeats and across transitions between two
/// non-recording phases. Value type holding a single edge bit; the host owns one
/// instance for the app's lifetime.
public struct RecordingCueGate: Sendable {
  private var wasRecording = false

  public init() {}

  /// The cue to play for `phase`, or `nil` when the recording edge didn't move.
  public mutating func cue(for phase: PipelinePhase) -> RecordingCue? {
    let isRecording = phase == .recording
    defer { wasRecording = isRecording }
    switch (wasRecording, isRecording) {
    case (false, true): return .start
    case (true, false): return .stop
    default: return nil
    }
  }
}
