import Testing

@testable import BlurtEngine

/// The overlay pill's visual state is a pure function of the pipeline phase.
/// Lifting that mapping into the engine lets `swift test` cover it (the AppKit
/// shell that renders it has no test target).
@Suite("PipelinePhase → OverlayUIState")
struct OverlayUIStateTests {
  /// The phase→pill projection, one row per `PipelinePhase` case with a fixed
  /// mapping. A table rather than a `@Test` apiece (the precedent
  /// `DictationKeyGateTests` sets): adding a phase case makes the missing row
  /// visible in one place, and a failure names the phase. The cases whose
  /// mapping carries a rationale — `.failed` and its `.apiKeyMissing`
  /// carve-out — stay as their own tests below.
  static let projections: [(phase: PipelinePhase, expected: OverlayUIState)] = [
    (.idle, .idle),
    // Its own pill state, not `.recording`: `.starting` exists because capture
    // hasn't begun, so projecting it onto the recording pill would show the
    // `● REC` tag and a live meter over a mic that isn't open yet.
    (.starting, .starting),
    (.recording, .recording),
    (.transcribing, .processing),
    // `.injecting` is a *working* phase, so it must not project to `.idle`: the
    // shell reads an idle projection as "dismiss the pill" and would start a
    // fade-out mid-dictation, blinking the pill out and back in before "Pasted".
    // Keeping it `.processing` holds the pill up continuously from transcribe
    // through paste; the terminal `.pasted` phase carries the notice.
    (.injecting, .processing),
    // A completed paste surfaces the quiet "Pasted" notice — the mirror of
    // `.noTarget`'s "Copied" — as a transient notice before settling to idle.
    (.pasted, .pasted),
    // A cancelled capture leaves no trace on the pill — same rest state as idle.
    (.cancelled, .idle),
    // Transcription succeeded but nothing editable was focused, so the pill
    // shows the neutral "copied to clipboard" notice rather than an error.
    (.noTarget, .noTarget),
  ]

  @Test("each phase projects to its pill state", arguments: projections)
  func phaseProjectsToOverlayState(phase: PipelinePhase, expected: OverlayUIState) {
    #expect(phase.overlayState == expected)
  }

  @Test func pastedIsATransientNotice() {
    // Pinned alongside the mapping: the "Pasted" pill must auto-clear rather
    // than stick, which is what makes it a notice and not a steady state.
    #expect(OverlayUIState.pasted.noticeDwellSeconds != nil)
  }

  @Test func failedMapsToErrorCarryingTheReason() {
    // The mapping projects the failure's localized description into the pill so
    // the reason reaches the user (hover tooltip + VoiceOver) instead of an
    // unexplained red flash.
    let phase = PipelinePhase.failed(.audioCaptureFailed(underlying: MicCaptureError.noInputDevice))
    #expect(phase.overlayState == .error(message: "Audio capture failed: No microphone is available."))
  }

  @Test func missingKeyFailureMapsToIdle() {
    // A missing API key is an expected setup state the shell routes to the
    // settings window — the pill stays calm idle rather than flashing red on
    // the way there. Every other failure keeps the error presentation.
    #expect(PipelinePhase.failed(.apiKeyMissing).overlayState == .idle)
  }

  @Test("setupBlocker names the failures that are unfinished setup, not faults")
  func setupBlockerClassification() {
    // The single classification both consumers derive from: this projection renders
    // a setup blocker as calm `.idle`, and the shell routes it to the settings
    // window. When each pattern-matched `.failed(.apiKeyMissing)` for itself,
    // adding a second blocker meant remembering both sites — miss the engine one
    // and the user gets a red flash; miss the shell one and the press silently does
    // nothing.
    #expect(PipelinePhase.failed(.apiKeyMissing).setupBlocker == .apiKeyMissing)
    // A genuine failure is not a setup state.
    #expect(PipelinePhase.failed(.targetAppLost).setupBlocker == nil)
    // Neither is any non-failed phase.
    for phase in [
      PipelinePhase.idle, .starting, .recording, .transcribing, .injecting, .pasted, .noTarget,
    ] {
      #expect(phase.setupBlocker == nil)
    }
    // And the pill projection agrees with the classification.
    #expect(PipelinePhase.failed(.apiKeyMissing).overlayState == .idle)
  }

  @Test func failedFallsBackWhenNoDescription() {
    // Defensive: every BlurtError supplies an errorDescription today, but the
    // mapping must still produce a non-empty message if one ever returns nil.
    if case .error(let message) = PipelinePhase.failed(.targetAppLost).overlayState {
      #expect(!message.isEmpty)
    } else {
      Issue.record("expected .error")
    }
  }
}

/// The pill's VoiceOver label is spoken to the user, so lock the exact wording
/// of every case here — the AppKit shell reads these strings verbatim and a
/// silent edit would otherwise ship an unannounced regression.
@Suite("OverlayUIState.accessibilityLabel")
struct OverlayUIStateAccessibilityLabelTests {
  /// One row per fixed-wording state. `.error` is excluded: its label is a rule
  /// (echo the carried message verbatim), not a constant, so it keeps its own test.
  static let labels: [(state: OverlayUIState, spoken: String)] = [
    (.idle, "Blurt."),
    (.starting, "Starting."),
    (.recording, "Recording."),
    (.processing, "Processing."),
    (.pasted, "Your dictation was pasted."),
    (.noTarget, "No text field focused. Your dictation was copied to the clipboard."),
  ]

  @Test("each state speaks its fixed label", arguments: labels)
  func stateSpeaksItsLabel(state: OverlayUIState, spoken: String) {
    #expect(state.accessibilityLabel == spoken)
  }

  @Test func errorLabelIsTheMessageVerbatim() {
    // The error case surfaces the failure reason directly as the spoken label,
    // so it must echo the message it carries with no wrapping.
    #expect(OverlayUIState.error(message: "AssemblyAI error 401.").accessibilityLabel == "AssemblyAI error 401.")
  }
}

/// `noticeDwellSeconds` decides whether the shell holds a state or flashes it
/// and reverts to `.idle` (nil = held), and for how long. Getting this wrong
/// would either pin a "copied" notice on the pill forever or drop the recording
/// indicator, so pin every case. The policy lives on the state (not in the
/// AppKit controller) so a new notice can't ship without a dwell, and the
/// asymmetry — errors linger to be read, a successful "Pasted" clears fast —
/// is pinned here.
@Suite("OverlayUIState.noticeDwellSeconds")
struct OverlayUIStateNoticeDwellTests {
  @Test func pastedClearsFastest() {
    #expect(OverlayUIState.pasted.noticeDwellSeconds == 0.8)
  }

  @Test func errorAndCopiedLingerLongEnoughToRead() {
    #expect(OverlayUIState.error(message: "boom").noticeDwellSeconds == 1.6)
    #expect(OverlayUIState.noTarget.noticeDwellSeconds == 1.6)
  }

  @Test func steadyStatesHaveNoDwell() {
    // Held for as long as the pipeline is in them — no auto-revert.
    #expect(OverlayUIState.idle.noticeDwellSeconds == nil)
    // `.starting` in particular: a dwell would auto-revert the pill to idle
    // mid-press, dismissing it while the mic was still opening.
    #expect(OverlayUIState.starting.noticeDwellSeconds == nil)
    #expect(OverlayUIState.recording.noticeDwellSeconds == nil)
    #expect(OverlayUIState.processing.noticeDwellSeconds == nil)
  }
}
