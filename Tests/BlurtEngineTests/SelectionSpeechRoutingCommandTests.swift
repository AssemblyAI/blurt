import Testing

@testable import BlurtEngine

@Suite("SelectionSpeechRouting · Command")
struct SelectionSpeechRoutingCommandTests {
  /// A command press: right ⌥, holdable unless told otherwise.
  private func command(_ routing: inout SelectionSpeechRouting, holds: Bool = true) -> [SelectionSpeechRouting.Action] {
    routing.press(key: .rightOption, action: .command, holds: holds)
  }

  /// A held command press, its command recorded and let go.
  private func spoken(_ routing: inout SelectionSpeechRouting) {
    _ = command(&routing)
    _ = routing.holdElapsed()
    _ = routing.submit(.release)
  }

  @Test("a command press reads no selection, and records once it proves itself by a tap or a hold")
  func skipsTheRead() {
    var tapped = SelectionSpeechRouting()
    #expect(command(&tapped, holds: false).isEmpty)
    #expect(tapped.keyLatched() == [.forward(.pressHandingBack(key: nil))])

    var held = SelectionSpeechRouting()
    #expect(command(&held) == [.startHoldTimer])
    #expect(held.holdElapsed() == [.forward(.pressHandingBack(key: nil))])
  }

  @Test("let go, or a combo, before the press proved itself does nothing")
  func unprovenPressDoesNothing() {
    var routing = SelectionSpeechRouting()
    _ = command(&routing)
    #expect(routing.submit(.cancel).isEmpty)
    #expect(routing.holdElapsed().isEmpty)
  }

  @Test("the command handed back is carried out, and its end frees the gate")
  func runs() {
    var routing = SelectionSpeechRouting()
    spoken(&routing)
    #expect(routing.sessionPhaseChanged(.handedBack("Open Slack.")) == [.runCommand("Open Slack.")])
    // A rewrite's end is not this command's.
    #expect(routing.rewriteFinished().isEmpty)
    #expect(routing.commandFinished() == [.resetGate])
  }

  @Test("a press abandons a command before its next step: the dictation key then dictates, any other is cleared")
  func pressAbandons() {
    var routing = SelectionSpeechRouting()
    spoken(&routing)
    _ = routing.sessionPhaseChanged(.handedBack("Open Slack."))
    #expect(
      routing.press(key: .rightCommand, action: .dictate, holds: true)
        == [.stopCommand, .forward(.press(key: .rightCommand))])
    #expect(routing.commandFinished().isEmpty)

    var other = SelectionSpeechRouting()
    spoken(&other)
    _ = other.sessionPhaseChanged(.handedBack("Open Slack."))
    #expect(command(&other) == [.stopCommand, .resetGate])
  }

  @Test("a gate stop while a command runs abandons it, as it stops a read")
  func gateStopAbandons() {
    var routing = SelectionSpeechRouting()
    spoken(&routing)
    _ = routing.sessionPhaseChanged(.handedBack("Mute."))
    #expect(routing.submit(.release) == [.stopCommand])
  }

  @Test("the recording cap handing back with the key still down runs it and clears the gate")
  func capHandsBack() {
    var routing = SelectionSpeechRouting()
    _ = command(&routing)
    _ = routing.holdElapsed()
    #expect(routing.sessionPhaseChanged(.handedBack("Mute.")) == [.runCommand("Mute."), .resetGate])
  }

  @Test("nothing said is a dictation ending without a key event, with nothing run")
  func nothingSaid() {
    var routing = SelectionSpeechRouting()
    spoken(&routing)
    #expect(routing.sessionPhaseChanged(.idle) == [.syncGateAfterSession])
  }

  @Test("a command is a command from the press until it's handed back, and never a rewrite")
  func recordsCommand() {
    var routing = SelectionSpeechRouting()
    _ = command(&routing)
    _ = routing.holdElapsed()
    #expect(routing.recordsCommand)
    #expect(!routing.recordsRewrite)
    _ = routing.submit(.release)
    #expect(routing.recordsCommand)
    _ = routing.sessionPhaseChanged(.handedBack("Mute."))
    #expect(!routing.recordsCommand)
  }

  @Test("a command's transcription shows as working on it; capture and notices are untouched")
  func transcriptionReadsCommanding() {
    #expect(PipelinePhase.transcribing.overlayState(whileSpeaking: false, commanding: true) == .commanding)
    #expect(PipelinePhase.recording.overlayState(whileSpeaking: false, commanding: true) == .recording)
    #expect(PipelinePhase.idle.overlayState(whileSpeaking: false, commanding: true) == .idle)
    #expect(OverlayUIState.done.noticeDwellSeconds == OverlayUIState.pasted.noticeDwellSeconds)
  }
}
