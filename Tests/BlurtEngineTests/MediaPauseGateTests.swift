import Testing

@testable import BlurtEngine

/// The music pause's decisions. The failures that matter: music left paused for
/// good (a missed resume), music resumed over a spoken answer, and a command's
/// own play/pause fought by Blurt's.
///
/// The host renders each phase and then tells the router, which calls
/// `pressSettled` whenever it's left at rest; `settle` stands in for that.
@Suite("MediaPauseGate")
struct MediaPauseGateTests {
  private func step(
    _ gate: inout MediaPauseGate, _ phase: PipelinePhase, enabled: Bool = true, command: Bool = false
  ) -> MediaPauseGate.Action? {
    gate.action(for: phase, isEnabled: enabled, recordsCommand: command)
  }

  @Test("a dictation pauses as it records and resumes as the mic closes")
  func dictation() {
    var gate = MediaPauseGate()
    #expect(step(&gate, .connecting) == nil)
    #expect(gate.pressSettled() == nil)
    #expect(step(&gate, .recording) == .pause)
    #expect(gate.pressSettled() == nil)
    #expect(step(&gate, .transcribing) == nil)
    #expect(gate.pressSettled() == .resume)
    #expect(gate.pressSettled() == nil)
    #expect(!gate.owesResume)
  }

  @Test("off, nothing is paused and nothing resumed")
  func disabled() {
    var gate = MediaPauseGate()
    #expect(step(&gate, .recording, enabled: false) == nil)
    #expect(step(&gate, .transcribing) == nil)
    #expect(gate.pressSettled() == nil)
  }

  @Test("turned off mid-dictation, what was paused is still resumed")
  func disabledMidDictation() {
    var gate = MediaPauseGate()
    #expect(step(&gate, .recording) == .pause)
    #expect(step(&gate, .transcribing, enabled: false) == nil)
    #expect(gate.pressSettled() == .resume)
  }

  @Test("an ask's music waits for the router to settle after its answer")
  func askHoldsTheResume() {
    var gate = MediaPauseGate()
    #expect(step(&gate, .recording) == .pause)
    #expect(step(&gate, .transcribing) == nil)
    #expect(step(&gate, .handedBack("what's this?")) == nil)
    // The router speaks the answer; only when it's back at rest:
    #expect(gate.pressSettled() == .resume)
  }

  @Test("a command's recording is never paused, so its play/pause isn't fought")
  func commandIsLeftAlone() {
    var gate = MediaPauseGate()
    #expect(step(&gate, .recording, command: true) == nil)
    #expect(step(&gate, .transcribing) == nil)
    #expect(gate.pressSettled() == nil)
  }

  @Test("a dictation starting while a resume is still owed owes just the one")
  func overlappingPause() {
    var gate = MediaPauseGate()
    #expect(step(&gate, .recording) == .pause)
    #expect(step(&gate, .transcribing) == nil)
    // A second dictation before the router settled: paused again, the mic open.
    #expect(step(&gate, .recording) == .pause)
    #expect(gate.pressSettled() == nil && gate.owesResume)
    #expect(step(&gate, .pasted) == nil)
    #expect([gate.pressSettled(), gate.pressSettled()] == [.resume, nil])
  }
}
