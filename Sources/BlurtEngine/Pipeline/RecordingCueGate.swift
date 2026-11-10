/// Which record cue chime a pipeline-phase change should fire, if any. A pure
/// projection of `PipelinePhase` transitions — owned here (rather than in the
/// AppKit `CueSoundPlayer`) so the edge logic is unit-testable, the same split
/// as `OverlayUIState` and `MenuBarStatus`. The AppKit side just plays whichever
/// sound this resolves to.
public enum RecordingCue: Equatable, Sendable {
  case start
  case stop
}

/// Which record cue chime fires on each recording edge. The host calls
/// `cue(for:)` on *every* pipeline phase, so the gate fires `.start` only on the
/// edge into `.recording` and `.stop` only on the recording→not-recording edge,
/// staying silent while a phase repeats and across transitions between two
/// non-recording phases. Value type holding a single edge bit; the host owns one
/// instance for the app's lifetime.
///
/// The edge detection itself is `RecordingEdgeDetector` — shared with the media
/// pause/resume, which keys off the identical transitions. This type is the chime
/// half of that: which sound, on which edge.
///
/// The edge is `.recording` specifically, **not** "a press happened". In
/// production the press first claims `.connecting` while `MicCapture`'s liveness
/// gate waits for the input route to deliver frames, so the chime rides the
/// connecting→recording edge by construction — it sounds when audio is actually
/// flowing, not when the key went down. That ordering is the point: the chime is
/// a "speak now" cue, and on a Bluetooth route the two moments are ~1–2 s apart,
/// during which nothing is captured. Chiming at the press invites the user to
/// speak into a dead mic and loses the first words of the utterance.
public struct RecordingCueGate: Sendable {
  private var edges = RecordingEdgeDetector()

  public init() {}

  /// The cue to play for `phase`, or `nil` when the recording edge didn't move.
  public mutating func cue(for phase: PipelinePhase) -> RecordingCue? {
    switch edges.edge(for: phase) {
    case .began: return .start
    case .ended: return .stop
    case nil: return nil
    }
  }
}
