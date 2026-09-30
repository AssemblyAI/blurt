import Testing

@testable import BlurtEngine

@Suite("SelectionSpeechRouting")
struct SelectionSpeechRoutingTests {
  @Test("with the switch off, every command goes straight to the session")
  func switchedOff() {
    var routing = SelectionSpeechRouting()
    for command in [DictationSession.Command.press, .release, .cancel, .cancelRecording] {
      #expect(routing.submit(command, readAloudEnabled: false) == [.forward(command)])
    }
  }

  @Test("a press with nothing selected dictates, replaying what arrived during the read in order")
  func noSelectionReplays() {
    var routing = SelectionSpeechRouting()
    #expect(routing.submit(.press, readAloudEnabled: true) == [.readSelection])
    #expect(routing.submit(.release, readAloudEnabled: true).isEmpty)
    #expect(routing.selectionResolved(nil) == [.forward(.press), .forward(.release)])
    #expect(routing.submit(.press, readAloudEnabled: true) == [.readSelection])
  }

  @Test("a press over a selection speaks it, and the next key command stops it")
  func speaksThenStops() {
    var routing = SelectionSpeechRouting()
    _ = routing.submit(.press, readAloudEnabled: true)
    #expect(routing.selectionResolved("Hello there.") == [.speak("Hello there.")])
    #expect(routing.submit(.release, readAloudEnabled: true) == [.stopSpeech])
    // The key stop already left the gate idle, so a late finish is nothing.
    #expect(routing.speechFinished().isEmpty)
  }

  @Test("a combo cancel during the read drops the press — ⌘C over a selection is a copy")
  func comboDuringRead() {
    var routing = SelectionSpeechRouting()
    _ = routing.submit(.press, readAloudEnabled: true)
    _ = routing.submit(.cancel, readAloudEnabled: true)
    #expect(routing.selectionResolved("Hello there.").isEmpty)
    #expect(routing.submit(.press, readAloudEnabled: false) == [.forward(.press)])
  }

  @Test("a recovery reset while speaking stops the read and still reaches the session")
  func recoveryWhileSpeaking() {
    var routing = SelectionSpeechRouting()
    _ = routing.submit(.press, readAloudEnabled: true)
    _ = routing.selectionResolved("Hello there.")
    #expect(
      routing.submit(.cancelRecording, readAloudEnabled: true)
        == [.stopSpeech, .forward(.cancelRecording)])
  }

  @Test("a read that ends on its own clears the gate silently")
  func naturalEnd() {
    var routing = SelectionSpeechRouting()
    _ = routing.submit(.press, readAloudEnabled: true)
    _ = routing.selectionResolved("Hello there.")
    #expect(routing.speechFinished() == [.resetGate])
    #expect(routing.submit(.press, readAloudEnabled: false) == [.forward(.press)])
  }

  @Test("a dictation's terminal phase syncs the gate only while commands go to the session")
  func terminalPhaseOwnership() {
    var routing = SelectionSpeechRouting()
    #expect(routing.sessionReachedTerminalPhase() == [.syncGateAfterSession])
    _ = routing.submit(.press, readAloudEnabled: true)
    #expect(routing.sessionReachedTerminalPhase().isEmpty)
    _ = routing.selectionResolved("Hello there.")
    // The earlier dictation finishing mid-read must not reset the read's gate.
    #expect(routing.sessionReachedTerminalPhase().isEmpty)
  }

  @Test("a stale selection result after the press resolved is ignored")
  func staleResolution() {
    var routing = SelectionSpeechRouting()
    #expect(routing.selectionResolved("Hello there.").isEmpty)
  }
}
