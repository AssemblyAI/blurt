import Foundation
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
    // Its own pill state, not `.recording`: `.connecting` exists because capture
    // hasn't begun, so projecting it onto the recording pill would show the
    // `● REC` tag and a live meter over a mic that isn't open yet.
    (.connecting, .connecting),
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

  @Test
  func pastedIsATransientNotice() {
    // Pinned alongside the mapping: the "Pasted" pill must auto-clear rather
    // than stick, which is what makes it a notice and not a steady state.
    #expect(OverlayUIState.pasted.noticeDwellSeconds != nil)
  }

  @Test
  func failedMapsToErrorCarryingTheReason() {
    // The mapping projects the failure's localized description into the pill so
    // the reason reaches the user (hover tooltip + VoiceOver) instead of an
    // unexplained red flash.
    let phase = PipelinePhase.failed(.audioCaptureFailed(underlying: MicCaptureError.noInputDevice))
    #expect(phase.overlayState == .error(message: "No microphone is available."))
  }

  @Test
  func silentMicFailureNamesTheDeviceOnThePill() {
    // An error carrying a pill notice, so the shell can widen the pill and show
    // the device name — the whole diagnosis — instead of hiding it on hover.
    let error = MicCaptureError.inputNeverDelivered(deviceName: "Aggregate Device")
    let state = PipelinePhase.failed(.audioCaptureFailed(underlying: error)).overlayState
    #expect(
      state
        == .error(
          message: "Aggregate Device isn't sending any audio.",
          notice: PillNotice(subject: "Aggregate Device", predicate: "isn't sending any audio")
        ))
    #expect(state.pillNotice?.text == "Aggregate Device isn't sending any audio")
    #expect(state.pillNotice?.subject == "Aggregate Device")
    #expect(state.pillNotice?.predicate == "isn't sending any audio")
    #expect(state.accessibilityLabel == "Aggregate Device isn't sending any audio.")
    #expect(state.noticeDwellSeconds != nil)
  }

  @Test
  func silentMicFailureWithoutANameStillSaysWhatHappened() {
    let error = MicCaptureError.inputNeverDelivered(deviceName: nil)
    let state = PipelinePhase.failed(.audioCaptureFailed(underlying: error)).overlayState
    #expect(state.pillNotice?.text == "The microphone isn't sending any audio")
    #expect(state.accessibilityLabel == "The microphone isn't sending any audio.")
  }

  @Test
  func onlyTheSilentMicNoticeWritesOnThePill() {
    // Every other state is a status word or the meter; a pill-text there would
    // widen the pill for it too.
    let others: [OverlayUIState] = [
      .idle, .connecting, .recording, .processing, .error(message: "x"), .pasted, .noTarget,
    ]
    #expect(others.allSatisfy { $0.pillNotice == nil })
  }

  @Test
  func foreignCaptureErrorsKeepTheirContext() {
    // A conformer's untyped error has no user-facing framing of its own.
    let error = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Boom."])
    let phase = PipelinePhase.failed(.audioCaptureFailed(underlying: error))
    #expect(phase.overlayState == .error(message: "Audio capture failed: Boom."))
  }

  /// A host's own capture source (the iPhone's listening window) words its
  /// errors for the user; the phase says them as they are.
  private struct HostCaptureFailure: CaptureFailureWording {
    var errorDescription: String? { "A call or another app has the microphone." }
  }

  @Test
  func userWordedCaptureErrorsDropThePrefix() {
    let phase = PipelinePhase.failed(.audioCaptureFailed(underlying: HostCaptureFailure()))
    #expect(phase.overlayState == .error(message: "A call or another app has the microphone."))
  }

  @Test
  func missingKeyFailureMapsToIdle() {
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
      PipelinePhase.idle, .connecting, .recording, .transcribing, .injecting, .pasted, .noTarget,
    ] {
      #expect(phase.setupBlocker == nil)
    }
    // And the pill projection agrees with the classification.
    #expect(PipelinePhase.failed(.apiKeyMissing).overlayState == .idle)
  }

  @Test
  func failedFallsBackWhenNoDescription() {
    // Defensive: every BlurtError supplies an errorDescription today, but the
    // mapping must still produce a non-empty message if one ever returns nil.
    if case .error(let message, _) = PipelinePhase.failed(.targetAppLost).overlayState {
      #expect(!message.isEmpty)
    } else {
      Issue.record("expected .error")
    }
  }
}
