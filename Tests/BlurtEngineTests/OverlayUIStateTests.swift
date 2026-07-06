import Testing

@testable import BlurtEngine

/// The overlay pill's visual state is a pure function of the pipeline phase.
/// Lifting that mapping into the engine lets `swift test` cover it (the AppKit
/// shell that renders it has no test target).
@Suite("PipelinePhase → OverlayUIState")
struct OverlayUIStateTests {
  @Test func idleMapsToIdle() {
    #expect(PipelinePhase.idle.overlayState == .idle)
  }

  @Test func recordingMapsToRecording() {
    #expect(PipelinePhase.recording.overlayState == .recording)
  }

  @Test func transcribingMapsToProcessing() {
    #expect(PipelinePhase.transcribing.overlayState == .processing)
  }

  @Test func injectingMapsToIdle() {
    // The in-flight injecting phase shows no distinct pill; the terminal
    // `.pasted` phase (set once the paste lands) carries the "Pasted" notice.
    #expect(PipelinePhase.injecting.overlayState == .idle)
  }

  @Test func pastedMapsToPasted() {
    // A completed paste surfaces the quiet "Pasted" notice — the mirror of
    // `.noTarget`'s "Copied" — as a transient notice before settling to idle.
    #expect(PipelinePhase.pasted.overlayState == .pasted)
    #expect(OverlayUIState.pasted.isTransientNotice)
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

  @Test func failedFallsBackWhenNoDescription() {
    // Defensive: every BlurtError supplies an errorDescription today, but the
    // mapping must still produce a non-empty message if one ever returns nil.
    if case .error(let message) = PipelinePhase.failed(.targetAppLost).overlayState {
      #expect(!message.isEmpty)
    } else {
      Issue.record("expected .error")
    }
  }

  @Test func cancelledMapsToIdle() {
    // A cancelled capture leaves no trace on the pill — same rest state as idle.
    #expect(PipelinePhase.cancelled.overlayState == .idle)
  }

  @Test func noTargetMapsToNoTarget() {
    // Transcription succeeded but nothing editable was focused, so the pill
    // shows the neutral "copied to clipboard" notice rather than an error.
    #expect(PipelinePhase.noTarget.overlayState == .noTarget)
  }
}

/// The pill's VoiceOver label is spoken to the user, so lock the exact wording
/// of every case here — the AppKit shell reads these strings verbatim and a
/// silent edit would otherwise ship an unannounced regression.
@Suite("OverlayUIState.accessibilityLabel")
struct OverlayUIStateAccessibilityLabelTests {
  @Test func idleLabel() {
    #expect(OverlayUIState.idle.accessibilityLabel == "Blurt.")
  }

  @Test func recordingLabel() {
    #expect(OverlayUIState.recording.accessibilityLabel == "Recording.")
  }

  @Test func processingLabel() {
    #expect(OverlayUIState.processing.accessibilityLabel == "Processing.")
  }

  @Test func errorLabelIsTheMessageVerbatim() {
    // The error case surfaces the failure reason directly as the spoken label,
    // so it must echo the message it carries with no wrapping.
    #expect(OverlayUIState.error(message: "AssemblyAI error 401.").accessibilityLabel == "AssemblyAI error 401.")
  }

  @Test func pastedLabel() {
    #expect(OverlayUIState.pasted.accessibilityLabel == "Your dictation was pasted.")
  }

  @Test func noTargetLabel() {
    #expect(
      OverlayUIState.noTarget.accessibilityLabel
        == "No text field focused. Your dictation was copied to the clipboard."
    )
  }
}

/// `isTransientNotice` decides whether the shell holds a state or flashes it and
/// reverts to `.idle`. Getting this wrong would either pin a "copied" notice on
/// the pill forever or drop the recording indicator, so pin every case.
@Suite("OverlayUIState.isTransientNotice")
struct OverlayUIStateTransientNoticeTests {
  @Test func errorIsTransient() {
    #expect(OverlayUIState.error(message: "boom").isTransientNotice)
  }

  @Test func noTargetIsTransient() {
    #expect(OverlayUIState.noTarget.isTransientNotice)
  }

  @Test func steadyStatesAreNotTransient() {
    #expect(!OverlayUIState.idle.isTransientNotice)
    #expect(!OverlayUIState.recording.isTransientNotice)
    #expect(!OverlayUIState.processing.isTransientNotice)
  }
}

/// How long the shell holds each transient notice before reverting to `.idle`.
/// The policy lives on the state (not in the AppKit controller) so a new notice
/// can't ship without a dwell, and the asymmetry — errors linger to be read, a
/// successful "Pasted" clears fast — is pinned here.
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
    #expect(OverlayUIState.recording.noticeDwellSeconds == nil)
    #expect(OverlayUIState.processing.noticeDwellSeconds == nil)
  }
}
