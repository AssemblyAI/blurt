/// Which way the recording edge moved on a pipeline-phase change.
public enum RecordingEdge: Equatable, Sendable {
  case began
  case ended
}

/// Edge-detector over `PipelinePhase.recording`, for hosts that must act when a
/// recording starts and undo it when the recording stops.
///
/// The host calls `edge(for:)` on *every* pipeline phase, so this reports
/// `.began` only on the not-recording→recording transition and `.ended` only on
/// the recording→not-recording one, staying silent while a phase repeats and
/// across transitions between two non-recording phases (`.transcribing` →
/// `.pasted`, say). Value type holding a single edge bit; the host owns one
/// instance for the app's lifetime.
///
/// Extracted from `RecordingCueGate`, which is now a thin mapping over it: the
/// chimes and the media pause/resume want the identical edges and had no
/// business each re-deriving them. Note `.ended` fires when the *mic* stops, not
/// when the dictation reaches a terminal phase — the transcribe/inject tail is no
/// longer recording, so anything suppressed for the microphone's benefit should
/// be restored there rather than a second or two later.
public struct RecordingEdgeDetector: Sendable {
  private var wasRecording = false

  public init() {}

  /// The edge `phase` crossed, or `nil` when the recording state didn't move.
  public mutating func edge(for phase: PipelinePhase) -> RecordingEdge? {
    let isRecording = phase == .recording
    defer { wasRecording = isRecording }
    switch (wasRecording, isRecording) {
    case (false, true): return .began
    case (true, false): return .ended
    default: return nil
    }
  }
}
