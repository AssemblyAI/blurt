import Testing

@testable import BlurtEngine

/// `PipelinePhase.isCapturing` gates the ready screen's style-switch lock (and,
/// through `menuBarStatus`, its listening state), so the boundary cases carry
/// the meaning: `.connecting` counts — a style switched during the mic bring-up
/// would still disagree with the request — while `.transcribing` does not, the
/// audio being already sealed.
@Suite("PipelinePhase.isCapturing")
struct PipelinePhaseIsCapturingTests {
  @Test("exactly the bring-up and recording phases count as capturing")
  func capturingCoversBringUpAndRecording() {
    #expect(PipelinePhase.connecting.isCapturing)
    #expect(PipelinePhase.recording.isCapturing)
    #expect(!PipelinePhase.idle.isCapturing)
    #expect(!PipelinePhase.transcribing.isCapturing)
    #expect(!PipelinePhase.injecting.isCapturing)
    #expect(!PipelinePhase.cancelled.isCapturing)
    #expect(!PipelinePhase.pasted.isCapturing)
    #expect(!PipelinePhase.noTarget.isCapturing)
    #expect(!PipelinePhase.failed(.apiKeyMissing).isCapturing)
  }
}
