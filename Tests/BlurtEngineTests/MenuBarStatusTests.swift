import Testing

@testable import BlurtEngine

/// The menu bar status item's state is a pure function of the pipeline phase.
/// Lifting that mapping into the engine lets `swift test` cover it (the SwiftUI
/// shell that renders it has no test target).
@Suite("PipelinePhase → MenuBarStatus")
struct MenuBarStatusTests {
  @Test func recordingMapsToRecording() {
    #expect(PipelinePhase.recording.menuBarStatus == .recording)
  }

  @Test func transcribingMapsToTranscribing() {
    #expect(PipelinePhase.transcribing.menuBarStatus == .transcribing)
  }

  @Test func idleMapsToIdle() {
    #expect(PipelinePhase.idle.menuBarStatus == .idle)
  }

  @Test func injectingMapsToIdle() {
    // Injection happens silently; the indicator rests at idle through the brief
    // paste rather than showing a distinct state.
    #expect(PipelinePhase.injecting.menuBarStatus == .idle)
  }

  @Test func cancelledMapsToIdle() {
    #expect(PipelinePhase.cancelled.menuBarStatus == .idle)
  }

  @Test func pastedMapsToIdle() {
    // The completed-paste notice lives on the pill; the menu bar stays idle.
    #expect(PipelinePhase.pasted.menuBarStatus == .idle)
  }

  @Test func failedMapsToIdle() {
    // Unlike the overlay pill (which flashes red), the menu bar deliberately
    // doesn't surface the transient error — so a handled failure reads as idle,
    // and the icon can't get stranded on a state nothing transitions out of (the
    // pill's error revert is timer-driven, not a follow-up phase).
    #expect(PipelinePhase.failed(.targetAppLost).menuBarStatus == .idle)
  }
}
