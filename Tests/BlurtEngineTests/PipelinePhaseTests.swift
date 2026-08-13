import Testing

@testable import BlurtEngine

@Suite("PipelinePhase.isTerminal")
struct PipelinePhaseTests {
  @Test("idle is terminal")
  func idleIsTerminal() {
    #expect(PipelinePhase.idle.isTerminal)
  }

  @Test("failed is terminal regardless of underlying error")
  func failedIsTerminal() {
    #expect(PipelinePhase.failed(.apiKeyMissing).isTerminal)
    #expect(PipelinePhase.failed(.targetAppLost).isTerminal)
  }

  @Test("pasted is terminal")
  func pastedIsTerminal() {
    #expect(PipelinePhase.pasted.isTerminal)
  }

  @Test("cancelled is terminal")
  func cancelledIsTerminal() {
    // `waitForIdle` and the press guard both key off terminality — a
    // non-terminal .cancelled would block every press after a cancel.
    #expect(PipelinePhase.cancelled.isTerminal)
  }

  @Test("active phases are not terminal")
  func activePhasesAreNotTerminal() {
    // `.starting` included: the press guard keys off terminality, so a terminal
    // `.starting` would let a second key-down start a second capture while the
    // first is still opening the mic — the exact window it was added to cover.
    #expect(!PipelinePhase.starting.isTerminal)
    #expect(!PipelinePhase.recording.isTerminal)
    #expect(!PipelinePhase.transcribing.isTerminal)
    #expect(!PipelinePhase.injecting.isTerminal)
  }
}

/// `isCapturing` is the single definition of "a dictation is being captured
/// right now" — the edge the start/stop chimes ride. Pinned per case: a phase
/// wrongly reading as capturing would chime at the wrong moment, and `.starting`
/// wrongly reading as *not* capturing would put the start chime back where it
/// was, after the hardware route comes up.
@Suite("PipelinePhase.isCapturing")
struct PipelinePhaseCapturingTests {
  @Test("the mic is open, or opening")
  func capturingPhases() {
    #expect(PipelinePhase.starting.isCapturing)
    #expect(PipelinePhase.recording.isCapturing)
  }

  @Test("every other phase is not capturing")
  func nonCapturingPhases() {
    for phase: PipelinePhase in [
      .idle, .transcribing, .injecting, .cancelled, .pasted, .noTarget,
      .failed(.apiKeyMissing),
    ] {
      #expect(!phase.isCapturing, "\(phase) must not read as capturing")
    }
  }
}
