import Testing

@testable import BlurtEngine

/// The record start/stop chimes fire on the *edges* of the recording phase, not
/// on every phase tick. `AppCoordinator.render` calls the cue gate on every
/// pipeline phase (idle, recording, transcribing, injecting, pasted, …), so the
/// gate must fire `.start` only on the idle→recording edge and `.stop` only on
/// the recording→not-recording edge, staying silent on repeats and on
/// transitions between two non-recording phases. Lifting that edge detection out
/// of the AppKit `CueSoundPlayer` lets `swift test` cover it — the same split as
/// `OverlayUIState`/`MenuBarStatus`.
@Suite("RecordingCueGate")
struct RecordingCueGateTests {
  @Test("entering recording from idle fires the start cue")
  func startOnRisingEdge() {
    var gate = RecordingCueGate()
    #expect(gate.cue(for: .recording) == .start)
  }

  @Test("leaving recording fires the stop cue")
  func stopOnFallingEdge() {
    var gate = RecordingCueGate()
    _ = gate.cue(for: .recording)
    #expect(gate.cue(for: .transcribing) == .stop)
  }

  @Test("staying in recording does not re-fire the start cue")
  func noRepeatWhileRecording() {
    var gate = RecordingCueGate()
    #expect(gate.cue(for: .recording) == .start)
    #expect(gate.cue(for: .recording) == nil)
  }

  @Test("transitions between two non-recording phases are silent")
  func silentBetweenNonRecordingPhases() {
    var gate = RecordingCueGate()
    // From the initial (non-recording) state through a run of non-recording
    // phases, nothing chimes — only a recording edge does.
    #expect(gate.cue(for: .idle) == nil)
    #expect(gate.cue(for: .transcribing) == nil)
    #expect(gate.cue(for: .injecting) == nil)
    #expect(gate.cue(for: .pasted) == nil)
    #expect(gate.cue(for: .failed(.apiKeyMissing)) == nil)
  }

  @Test("a full record→stop→record cycle chimes start, stop, start again")
  func fullCycle() {
    var gate = RecordingCueGate()
    #expect(gate.cue(for: .recording) == .start)
    #expect(gate.cue(for: .injecting) == .stop)
    #expect(gate.cue(for: .idle) == nil)
    #expect(gate.cue(for: .recording) == .start)
  }
}
