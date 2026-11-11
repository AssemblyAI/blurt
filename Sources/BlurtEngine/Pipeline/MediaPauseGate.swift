/// What the music pause does on a pipeline-phase change, or when the selection
/// router is at rest: the pure decisions behind the app's `MediaPauseController`,
/// which only carries them out. Owned here so they're unit-testable, the same
/// split as `RecordingCueGate` and `CueSoundPlayer`.
///
/// The pause rides the edge into recording (`RecordingEdgeDetector`). The
/// resume comes from `pressSettled` — the router at rest — once the mic has
/// closed:
///
/// - **A dictation** never takes the router out of rest, so its music comes back
///   in the very render its mic closes in, not a second later when the paste lands.
/// - **An ask** goes on to speak its answer, and a rewrite or a composition to
///   paste: the router is busy until then, so the music doesn't play over the
///   spoken answer.
/// - **A command** isn't paused at all. The command may be about the music
///   ("pause the music"), and the planner's play/pause key would toggle the
///   player Blurt paused back on: the user's music is theirs to command.
public struct MediaPauseGate: Sendable {
  public enum Action: Equatable, Sendable {
    case pause
    case resume
  }

  private var edges = RecordingEdgeDetector()
  /// A pause was queued and its resume wasn't yet.
  private(set) var owesResume = false

  public init() {}

  /// The action for `phase`: a pause on the edge into recording, unless it's a
  /// command's (`recordsCommand`) or the switch is off. `isEnabled` only counts
  /// on that edge, so a switch turned off mid-dictation still resumes what it
  /// paused.
  public mutating func action(for phase: PipelinePhase, isEnabled: Bool, recordsCommand: Bool) -> Action? {
    guard edges.edge(for: phase) == .began, isEnabled, !recordsCommand else { return nil }
    owesResume = true
    return .pause
  }

  /// The router is at rest (`SelectionSpeechRouter.pressSettled`, called after
  /// every routing step that leaves it there — a level, not an edge): the resume
  /// is due, unless the mic is still open.
  public mutating func pressSettled() -> Action? {
    guard owesResume, !edges.isRecording else { return nil }
    owesResume = false
    return .resume
  }
}
