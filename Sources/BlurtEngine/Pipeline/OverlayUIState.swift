/// The visual state of the dictation overlay pill. It's a pure projection of
/// `PipelinePhase` — owned here (rather than in the AppKit shell) so the mapping
/// is unit-testable; the shell just renders whatever this resolves to.
public enum OverlayUIState: Equatable, Sendable {
  case idle
  /// The press landed but the mic isn't delivering audio yet (the pipeline's
  /// `.connecting` phase — a Bluetooth route takes ~1–2 s to come up). A steady
  /// state, not a notice: it holds for exactly as long as the hardware takes,
  /// which is a frame or two on the built-in mic. The shell renders it as a
  /// breathing "Connecting…" status line, deliberately *without* the `● REC`
  /// tag or the meter — those are the "speak now" cues, and speech during the
  /// bring-up is unrecoverable, so the pill must not invite it.
  case connecting
  case recording
  case processing
  /// A dictation attempt failed. The shell shows this as a brief red flash on
  /// the pill before settling back to `.idle`; `message` is the human-readable
  /// reason (e.g. "AssemblyAI error 401…"), surfaced via the pill's hover
  /// tooltip and VoiceOver announcement so the failure isn't an unexplained
  /// red dot.
  case error(message: String)
  /// The press failed because the input device delivered only silence (the
  /// liveness gate's fail-closed outcome). Split from `.error` because the
  /// device name is the whole diagnosis — an aggregate whose real interface is
  /// unplugged, or a loopback like BlackHole set as the default input — and a
  /// hover tooltip hides it. The shell widens the pill to show `pillText` for
  /// this notice alone; every other failure keeps the compact "Error" pill.
  case inputSilent(deviceName: String?)
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
    case .connecting: "Connecting to the microphone."
    case .recording: "Recording."
    case .processing: "Processing."
    case .error(let message): message
    case .inputSilent(let deviceName):
      MicCaptureError.inputNeverDelivered(deviceName: deviceName).errorDescription ?? ""
    case .pasted: "Your dictation was pasted."
    case .noTarget: "No text field focused. Your dictation was copied to the clipboard."
    }
  }

  /// How long the shell should hold this transient notice on the pill before
  /// auto-reverting to `.idle` (announcing it for VoiceOver first, since the
  /// non-activating pill never takes focus), or `nil` for a steady state held
  /// for as long as the pipeline is in it. A failed or "copied" notice lingers
  /// long enough to read; a successful "Pasted" needs far less, so it clears
  /// faster and the interaction feels snappier. Owned here so the dwell policy
  /// is unit-tested and a new notice can't ship without one.
  public var noticeDwellSeconds: Double? {
    switch self {
    case .pasted: 0.8
    case .error, .noTarget: 1.6
    // A sentence, not a word: long enough to read the device name.
    case .inputSilent: 3.0
    case .idle, .connecting, .recording, .processing: nil
    }
  }

  /// The words written on the pill for a notice that spells out its reason, or
  /// nil for the states the pill shows as a status word or meter. Split so the
  /// shell can truncate the subject (a device name of any length) and never the
  /// predicate, which is what says what went wrong. A status line, so no closing
  /// period — the sentence form is `accessibilityLabel`.
  public var pillNotice: (subject: String, predicate: String)? {
    switch self {
    case .inputSilent(let deviceName): (deviceName ?? "The microphone", "isn't sending any audio")
    case .idle, .connecting, .recording, .processing, .error, .pasted, .noTarget: nil
    }
  }

  /// `pillNotice` as the one line it reads as — what the shell measures.
  public var pillText: String? {
    pillNotice.map { "\($0.subject) \($0.predicate)" }
  }
}

extension PipelinePhase {
  /// How this phase should be presented on the overlay pill.
  public var overlayState: OverlayUIState {
    switch self {
    // `.handedBack` hides the pill: the transcript went to the host (an ask
    // about the selection, answered aloud), so there is nothing to confirm.
    case .idle, .cancelled, .handedBack: .idle
    // `.injecting` maps to `.processing`, NOT `.idle`. The shell reads an `.idle`
    // projection as "dismiss the pill", so mapping this working phase to idle
    // started a fade-out mid-dictation: two wasted animation groups on the fast
    // path, and on the slow one (the injector's activation wait runs up to 350 ms)
    // the fade completed, ordering the panel out and tearing down the pill's
    // content — then `.pasted` arrived and faded it back in. A visible blink at
    // the end of a dictation, worst when the user has switched apps mid-transcribe.
    case .injecting: .processing
    // Its own pill state, NOT `.recording`: the phase exists precisely because
    // capture hasn't begun, so projecting it onto the recording pill would put
    // the `● REC` tag and a live meter on screen over a mic that isn't
    // delivering yet — the "speak now" cue the whole gate exists to withhold.
    case .connecting: .connecting
    case .recording: .recording
    case .transcribing: .processing
    // A setup blocker (a missing API key) is an expected state, not a fault: the
    // shell routes it to the settings window — the actionable fix — so the pill
    // stays calm idle rather than flashing red on the way there. The
    // classification is `PipelinePhase.setupBlocker`, so this and the shell's
    // navigation can't disagree about which failures are setup states.
    case .failed(let error) where error.isSetupBlocker: .idle
    case .failed(let error):
      if case .audioCaptureFailed(let underlying as MicCaptureError) = error,
        case .inputNeverDelivered(let deviceName) = underlying
      {
        .inputSilent(deviceName: deviceName)
      } else {
        .error(message: error.errorDescription ?? "Dictation failed.")
      }
    case .pasted: .pasted
    case .noTarget: .noTarget
    }
  }
}
