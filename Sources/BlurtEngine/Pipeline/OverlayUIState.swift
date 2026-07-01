/// The visual state of the dictation overlay pill. It's a pure projection of
/// `PipelinePhase` — owned here (rather than in the AppKit shell) so the mapping
/// is unit-testable; the shell just renders whatever this resolves to.
public enum OverlayUIState: Equatable, Sendable {
  case idle
  case recording
  case processing
  /// A dictation attempt failed. The shell shows this as a brief red flash on
  /// the pill before settling back to `.idle`; `message` is the human-readable
  /// reason (e.g. "AssemblyAI error 401…"), surfaced via the pill's hover
  /// tooltip and VoiceOver announcement so the failure isn't an unexplained
  /// red dot.
  case error(message: String)
  /// Transcription succeeded and the text was pasted into the focused field. The
  /// shell shows this as a brief, neutral "Pasted" notice before settling to
  /// `.idle` — the mirror of the `.noTarget` "Copied" notice for the paste path.
  case pasted
  /// Transcription succeeded but nothing editable was focused, so the text was
  /// copied to the clipboard instead of typed. The shell shows this as a brief,
  /// neutral "Copied" notice (not the red error flash) before settling to `.idle`.
  case noTarget

  /// The VoiceOver label for the pill in this state. Owned here (not in the
  /// AppKit shell) so the wording is in one place: the shell reads it both as the
  /// pill's accessibility label and as the spoken announcement for the transient
  /// notices below, which would otherwise restate the same strings.
  public var accessibilityLabel: String {
    switch self {
    case .idle: "Blurt."
    case .recording: "Recording."
    case .processing: "Processing."
    case .error(let message): message
    case .pasted: "Your dictation was pasted."
    case .noTarget: "No text field focused. Your dictation was copied to the clipboard."
    }
  }

  /// Whether this is a brief notice the shell shows and then auto-reverts to
  /// `.idle` (error flash / "copied"), as opposed to a steady state held for as
  /// long as the pipeline is in it. The shell announces these for VoiceOver
  /// since the non-activating pill never takes focus.
  public var isTransientNotice: Bool {
    switch self {
    case .error, .pasted, .noTarget: true
    case .idle, .recording, .processing: false
    }
  }
}

extension PipelinePhase {
  /// How this phase should be presented on the overlay pill.
  public var overlayState: OverlayUIState {
    switch self {
    case .idle, .injecting, .cancelled: .idle
    case .recording: .recording
    case .transcribing: .processing
    case .failed(let error): .error(message: error.errorDescription ?? "Dictation failed.")
    case .pasted: .pasted
    case .noTarget: .noTarget
    }
  }
}
