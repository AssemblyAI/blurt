import Testing

@testable import BlurtEngine

/// The record start/stop chimes fire on the *edges* of `.recording`, not on
/// every phase tick. `AppCoordinator.render` calls the cue gate on every
/// pipeline phase (idle, connecting, recording, transcribing, injecting, pasted,
/// …), so the gate must fire `.start` only on the edge into `.recording` and
/// `.stop` only on the edge out of it, staying silent on repeats and on
/// transitions between two non-recording phases. Lifting that edge detection out
/// of the AppKit `CueSoundPlayer` lets `swift test` cover it — the same split as
/// `OverlayUIState`/`MenuBarStatus`.
@Suite("RecordingCueGate")
struct RecordingCueGateTests {
  @Test("entering recording fires the start cue")
  func startOnRisingEdge() {
    var gate = RecordingCueGate()
    #expect(gate.cue(for: .recording) == .start)
  }

  @Test("the mic bring-up is silent — the chime waits for audio to actually flow")
  func connectingIsSilent() {
    // The load-bearing case. `.connecting` is the window where `MicCapture`'s
    // liveness gate is waiting for the input route, which on a Bluetooth link is
    // ~1–2 s during which the OS captures nothing. A chime here is a "speak now"
    // cue for a dead mic, and the first words of the utterance are lost — the
    // exact bug this ordering exists to prevent.
    var gate = RecordingCueGate()
    #expect(gate.cue(for: .connecting) == nil)
    // It fires on the connecting→recording edge instead.
    #expect(gate.cue(for: .recording) == .start)
  }

  @Test("a press whose mic never comes up never chimes")
  func failedBringUpIsSilent() {
    // `mic.start()` throwing takes the pipeline `.connecting` → `.failed`
    // without ever reaching `.recording`. No start cue was played, so no stop
    // cue is owed either — and the gate must be left unlatched for the next
    // press rather than thinking a capture is still running.
    var gate = RecordingCueGate()
    #expect(gate.cue(for: .connecting) == nil)
    let failure = PipelinePhase.failed(.audioCaptureFailed(underlying: MicCaptureError.noInputDevice))
    #expect(gate.cue(for: failure) == nil)
    #expect(gate.cue(for: .connecting) == nil)
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

  @Test("a full press→record→stop→press cycle chimes start, stop, start again")
  func fullCycle() {
    var gate = RecordingCueGate()
    #expect(gate.cue(for: .connecting) == nil)
    #expect(gate.cue(for: .recording) == .start)
    #expect(gate.cue(for: .injecting) == .stop)
    #expect(gate.cue(for: .idle) == nil)
    #expect(gate.cue(for: .connecting) == nil)
    #expect(gate.cue(for: .recording) == .start)
  }
}
