import Testing

@testable import BlurtEngine

@Suite("SelectionSpeechRouting · Rewrite")
struct SelectionSpeechRoutingRewriteTests {
  /// A rewrite press: right ⌥, holdable unless told otherwise.
  private func rewrite(_ routing: inout SelectionSpeechRouting, holds: Bool = true) -> [SelectionSpeechRouting.Action] {
    routing.press(key: .rightOption, action: .rewrite, holds: holds)
  }

  /// A held rewrite press over `selection`, its instruction recorded and let go.
  private func spoken(_ routing: inout SelectionSpeechRouting, over selection: String = "hey all") {
    _ = rewrite(&routing)
    _ = routing.selectionResolved(selection)
    _ = routing.holdElapsed()
    _ = routing.submit(.release)
  }

  @Test("a rewrite key tapped before the selection read returns records its instruction once it lands")
  func recordsInstruction() {
    var routing = SelectionSpeechRouting()
    #expect(rewrite(&routing, holds: false) == [.readSelection])
    #expect(routing.keyLatched().isEmpty)
    #expect(routing.selectionResolved("hey all") == [.forward(.pressHandingBack(key: nil))])
  }

  @Test("the instruction handed back rewrites the selection, and its end frees the gate")
  func rewrites() {
    var routing = SelectionSpeechRouting()
    spoken(&routing)
    #expect(
      routing.sessionPhaseChanged(.handedBack("Make it more formal."))
        == [.rewrite(request: "Make it more formal.", selection: "hey all")])
    // An answer's end is not this rewrite's.
    #expect(routing.speechFinished().isEmpty)
    #expect(routing.jobFinished() == [.resetGate])
  }

  @Test("a press abandons a rewrite before it pastes: the dictation key then dictates, any other is cleared")
  func pressAbandonsRewrite() {
    var routing = SelectionSpeechRouting()
    spoken(&routing)
    _ = routing.sessionPhaseChanged(.handedBack("Shorter."))
    #expect(
      routing.press(key: .rightCommand, action: .dictate, holds: true)
        == [.stopJob, .forward(.press(key: .rightCommand))])
    // The router stopped it, so its late end is nothing.
    #expect(routing.jobFinished().isEmpty)

    var other = SelectionSpeechRouting()
    spoken(&other)
    _ = other.sessionPhaseChanged(.handedBack("Shorter."))
    #expect(rewrite(&other) == [.stopJob, .resetGate])
  }

  @Test("a held rewrite let go before the gate's threshold ends the instruction, rather than latching")
  func shortHeldRewriteEnds() {
    var routing = SelectionSpeechRouting()
    _ = rewrite(&routing)
    _ = routing.selectionResolved("hey all")
    _ = routing.holdElapsed()
    #expect(routing.keyLatched() == [.forward(.release), .resetGate])
    #expect(
      routing.sessionPhaseChanged(.handedBack("Formal."))
        == [.rewrite(request: "Formal.", selection: "hey all")])
  }

  @Test("a held rewrite let go before the selection read returns asks nothing, and frees the gate")
  func shortHeldRewriteBeforeRead() {
    var routing = SelectionSpeechRouting()
    _ = rewrite(&routing)
    _ = routing.holdElapsed()
    #expect(routing.keyLatched() == [.resetGate])
    #expect(routing.selectionResolved("hey all").isEmpty)
  }

  @Test("the recording cap handing back with the key still down rewrites and clears the gate")
  func capHandsBack() {
    var routing = SelectionSpeechRouting()
    _ = rewrite(&routing)
    _ = routing.selectionResolved("hey all")
    _ = routing.holdElapsed()
    #expect(
      routing.sessionPhaseChanged(.handedBack("Formal."))
        == [.rewrite(request: "Formal.", selection: "hey all"), .resetGate])
  }

  @Test("nothing said is a dictation ending without a key event, with nothing rewritten")
  func nothingSaid() {
    var routing = SelectionSpeechRouting()
    spoken(&routing)
    #expect(routing.sessionPhaseChanged(.idle) == [.syncGateAfterSession])
  }

  @Test("a rewrite's instruction shows as Rewriting from the press until it's handed back; an ask's never does")
  func processingState() {
    var routing = SelectionSpeechRouting()
    _ = rewrite(&routing)
    _ = routing.selectionResolved("hey all")
    _ = routing.holdElapsed()
    #expect(routing.processingState == .rewriting)
    _ = routing.submit(.release)
    #expect(routing.processingState == .rewriting)
    _ = routing.sessionPhaseChanged(.handedBack("Formal."))
    #expect(routing.processingState == nil)

    var asking = SelectionSpeechRouting()
    _ = asking.press(key: .leftControl, action: .ask, holds: true)
    _ = asking.selectionResolved("hey all")
    _ = asking.holdElapsed()
    #expect(asking.processingState == nil)
  }

  @Test("a rewrite's transcription shows as Rewriting; capture and notices are untouched")
  func transcriptionReadsRewriting() {
    #expect(PipelinePhase.transcribing.overlayState(whileSpeaking: false, processingAs: .rewriting) == .rewriting)
    #expect(PipelinePhase.transcribing.overlayState(whileSpeaking: false) == .processing)
    #expect(PipelinePhase.recording.overlayState(whileSpeaking: false, processingAs: .rewriting) == .recording)
    #expect(PipelinePhase.idle.overlayState(whileSpeaking: false, processingAs: .rewriting) == .idle)
  }
}
