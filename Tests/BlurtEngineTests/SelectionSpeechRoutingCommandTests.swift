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
    #expect(tapped.keyLatched() == [.prepareCommand, .forward(.pressHandingBack(key: nil))])

    var held = SelectionSpeechRouting()
    #expect(command(&held) == [.startHoldTimer])
    #expect(held.holdElapsed() == [.prepareCommand, .forward(.pressHandingBack(key: nil))])
  }

  @Test("a command's screen is read the moment its recording ends, tapped or held, while it transcribes")
  func readsScreenAtRelease() {
    var tapped = SelectionSpeechRouting()
    _ = command(&tapped, holds: false)
    _ = tapped.keyLatched()
    #expect(tapped.submit(.release) == [.forward(.release), .readScreen])

    var held = SelectionSpeechRouting()
    _ = command(&held)
    _ = held.holdElapsed()
    #expect(held.keyLatched() == [.forward(.release), .resetGate, .readScreen])
  }

  @Test("a rewrite's release reads no screen, and nor does a command let go before its mic opened")
  func noScreenReadOtherwise() {
    var rewrite = SelectionSpeechRouting()
    _ = rewrite.press(key: .rightOption, action: .rewrite, holds: true)
    _ = rewrite.selectionResolved("hey all")
    _ = rewrite.holdElapsed()
    #expect(rewrite.submit(.release) == [.forward(.release)])

    var unstarted = SelectionSpeechRouting()
    _ = unstarted.sessionPhaseChanged(.transcribing)
    _ = command(&unstarted)
    _ = unstarted.holdElapsed()
    #expect(unstarted.submit(.release).isEmpty)
  }

  @Test("a command dropped before it runs — a press or a combo while it transcribes — stops its read and preparation")
  func abandonStops() {
    var pressed = SelectionSpeechRouting()
    spoken(&pressed)
    #expect(
      pressed.press(key: .rightCommand, action: .dictate, holds: true) == [.forward(.cancel), .resetGate, .stopJob])

    var combo = SelectionSpeechRouting()
    spoken(&combo)
    #expect(combo.submit(.cancel) == [.forward(.cancel), .stopJob])

    var recording = SelectionSpeechRouting()
    _ = command(&recording)
    _ = recording.holdElapsed()
    #expect(recording.submit(.cancel) == [.forward(.cancel), .stopJob])
  }

  @Test("a rewrite dropped the same way stops nothing: it has no read or preparation")
  func rewriteAbandonStopsNothing() {
    var routing = SelectionSpeechRouting()
    _ = routing.press(key: .rightOption, action: .rewrite, holds: true)
    _ = routing.selectionResolved("hey all")
    _ = routing.holdElapsed()
    _ = routing.submit(.release)
    #expect(routing.sessionPhaseChanged(.idle) == [.syncGateAfterSession])
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
    // A read's end is not this command's.
    #expect(routing.speechFinished().isEmpty)
    #expect(routing.jobFinished() == [.resetGate])
  }

  @Test("a press abandons a command before its next step: the dictation key then dictates, any other is cleared")
  func pressAbandons() {
    var routing = SelectionSpeechRouting()
    spoken(&routing)
    _ = routing.sessionPhaseChanged(.handedBack("Open Slack."))
    #expect(
      routing.press(key: .rightCommand, action: .dictate, holds: true)
        == [.stopJob, .forward(.press(key: .rightCommand))])
    #expect(routing.jobFinished().isEmpty)

    var other = SelectionSpeechRouting()
    spoken(&other)
    _ = other.sessionPhaseChanged(.handedBack("Open Slack."))
    #expect(command(&other) == [.stopJob, .resetGate])
  }

  @Test("a gate stop while a command runs abandons it, as it stops a read")
  func gateStopAbandons() {
    var routing = SelectionSpeechRouting()
    spoken(&routing)
    _ = routing.sessionPhaseChanged(.handedBack("Mute."))
    #expect(routing.submit(.release) == [.stopJob])
  }

  @Test("the recording cap handing back with the key still down runs it and clears the gate")
  func capHandsBack() {
    var routing = SelectionSpeechRouting()
    _ = command(&routing)
    _ = routing.holdElapsed()
    // It never passed through transcribing, so its screen is read now.
    #expect(routing.sessionPhaseChanged(.handedBack("Mute.")) == [.readScreen, .runCommand("Mute."), .resetGate])
  }

  @Test("nothing said is a dictation ending without a key event, with nothing run")
  func nothingSaid() {
    var routing = SelectionSpeechRouting()
    spoken(&routing)
    // Its screen read and preparation are dropped too.
    #expect(routing.sessionPhaseChanged(.idle) == [.syncGateAfterSession, .stopJob])
  }

  @Test("a command shows as Working from the press until it's handed back")
  func processingState() {
    var routing = SelectionSpeechRouting()
    _ = command(&routing)
    _ = routing.holdElapsed()
    #expect(routing.processingState == .commanding)
    _ = routing.submit(.release)
    #expect(routing.processingState == .commanding)
    _ = routing.sessionPhaseChanged(.handedBack("Mute."))
    #expect(routing.processingState == nil)
  }

  @Test("a command pressed while a dictation is finishing prepares at once, and records once the session is free")
  func preparesWhileBusy() {
    var routing = SelectionSpeechRouting()
    _ = routing.sessionPhaseChanged(.transcribing)
    _ = command(&routing)
    #expect(routing.holdElapsed() == [.prepareCommand])
    #expect(routing.sessionPhaseChanged(.idle) == [.forward(.pressHandingBack(key: nil))])
  }

  @Test("a command's transcription shows as working on it; capture and notices are untouched")
  func transcriptionReadsCommanding() {
    #expect(PipelinePhase.transcribing.overlayState(whileSpeaking: false, processingAs: .commanding) == .commanding)
    #expect(PipelinePhase.recording.overlayState(whileSpeaking: false, processingAs: .commanding) == .recording)
    #expect(PipelinePhase.idle.overlayState(whileSpeaking: false, processingAs: .commanding) == .idle)
    #expect(OverlayUIState.done.noticeDwellSeconds == OverlayUIState.pasted.noticeDwellSeconds)
  }
}
