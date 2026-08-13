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
/// edge into a capture and `.stop` only on the edge out of one, staying silent
/// while a phase repeats and across transitions between two non-capturing
/// phases. Value type holding a single edge bit; the host owns one instance for
/// the app's lifetime.
///
/// The edge is `PipelinePhase.isCapturing`, not `== .recording`, so the start
/// chime fires when the user presses the key (`.starting`) rather than when the
/// mic finishes opening. On a Bluetooth input those are hundreds of milliseconds
/// apart, and the chime is the fastest feedback the app has — holding it until
/// the route is live wasted exactly the interval it was there to cover. The
/// `.starting`→`.recording` step is inside one capture, so it stays silent.
public struct RecordingCueGate: Sendable {
  private var wasCapturing = false

  public init() {}

  /// The cue to play for `phase`, or `nil` when the capture edge didn't move.
  public mutating func cue(for phase: PipelinePhase) -> RecordingCue? {
    let isCapturing = phase.isCapturing
    defer { wasCapturing = isCapturing }
    switch (wasCapturing, isCapturing) {
    case (false, true): return .start
    case (true, false): return .stop
    default: return nil
    }
  }
}
