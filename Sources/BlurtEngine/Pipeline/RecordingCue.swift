/// Which record cue chime a pipeline-phase change should fire, if any. A pure
/// projection of `PipelinePhase` transitions — owned here (rather than in the
/// AppKit `CueSoundPlayer`) so the edge logic is unit-testable, the same split
/// as `OverlayUIState` and `MenuBarStatus`. The AppKit side just plays whichever
/// sound this resolves to.
public enum RecordingCue: Equatable, Sendable {
  case start
  case stop
}
