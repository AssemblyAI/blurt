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
    // `.connecting` included: the press guard keys off terminality, so a
    // terminal `.connecting` would let a second key-down start a second capture
    // while the first is still bringing the mic up — a window that lasts ~1–2 s
    // on a Bluetooth route, so it is very reachable.
    #expect(!PipelinePhase.connecting.isTerminal)
    #expect(!PipelinePhase.recording.isTerminal)
    #expect(!PipelinePhase.transcribing.isTerminal)
    #expect(!PipelinePhase.injecting.isTerminal)
  }
}
