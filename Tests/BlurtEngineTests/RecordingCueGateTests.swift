import Testing

@testable import BlurtEngine

/// The record start/stop chimes fire on the *edges* of a capture, not on every
/// phase tick. `AppCoordinator.render` calls the cue gate on every pipeline
/// phase (idle, starting, recording, transcribing, injecting, pasted, …), so the
/// gate must fire `.start` only on the edge into a capture and `.stop` only on
/// the edge out of one, staying silent on repeats and on transitions between two
/// non-capturing phases. Lifting that edge detection out of the AppKit
/// `CueSoundPlayer` lets `swift test` cover it — the same split as
/// `OverlayUIState`/`MenuBarStatus`.
@Suite("RecordingCueGate")
struct RecordingCueGateTests {
  @Test("the press fires the start cue, before the mic is open")
  func startOnPressEdge() {
    // The edge is `.starting`, not `.recording`. The chime is the app's fastest
    // feedback, and on a Bluetooth input those two phases are hundreds of
    // milliseconds apart — holding the chime until the route came up wasted
    // exactly the interval it was there to cover.
    var gate = RecordingCueGate()
    #expect(gate.cue(for: .starting) == .start)
  }

  @Test("the mic coming up mid-capture is silent")
  func noCueOnStartingToRecording() {
    // `.starting` → `.recording` is one capture continuing, not a new one.
    var gate = RecordingCueGate()
    #expect(gate.cue(for: .starting) == .start)
    #expect(gate.cue(for: .recording) == nil)
  }

  @Test("entering recording from idle fires the start cue")
  func startOnRisingEdge() {
    // A host that never observes `.starting` (a phase stream joined late) still
    // gets its start chime on the first capturing phase it does see.
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

  @Test("a press whose mic never opens still chimes closed")
  func failedStartClosesTheCue() {
    // `mic.start()` throwing takes the pipeline `.starting` → `.failed`. The
    // start chime has already played, so the stop chime is what keeps the pair
    // balanced — and it leaves the gate ready for the next press rather than
    // latched as if a capture were still running.
    var gate = RecordingCueGate()
    #expect(gate.cue(for: .starting) == .start)
    #expect(gate.cue(for: .failed(.audioCaptureFailed(underlying: MicCaptureError.noInputDevice))) == .stop)
    #expect(gate.cue(for: .starting) == .start)
  }

  @Test("transitions between two non-capturing phases are silent")
  func silentBetweenNonCapturingPhases() {
    var gate = RecordingCueGate()
    // From the initial (non-capturing) state through a run of non-capturing
    // phases, nothing chimes — only a capture edge does.
    #expect(gate.cue(for: .idle) == nil)
    #expect(gate.cue(for: .transcribing) == nil)
    #expect(gate.cue(for: .injecting) == nil)
    #expect(gate.cue(for: .pasted) == nil)
    #expect(gate.cue(for: .failed(.apiKeyMissing)) == nil)
  }

  @Test("a full record→stop→record cycle chimes start, stop, start again")
  func fullCycle() {
    var gate = RecordingCueGate()
    #expect(gate.cue(for: .starting) == .start)
    #expect(gate.cue(for: .recording) == nil)
    #expect(gate.cue(for: .injecting) == .stop)
    #expect(gate.cue(for: .idle) == nil)
    #expect(gate.cue(for: .starting) == .start)
  }
}
