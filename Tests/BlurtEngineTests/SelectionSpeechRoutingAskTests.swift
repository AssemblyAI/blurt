import Foundation
import Testing

@testable import BlurtEngine

@Suite("SelectionSpeechRouting · Ask")
struct SelectionSpeechRoutingAskTests {
  /// An ask press: left ⌃, holdable unless told otherwise.
  private func ask(_ routing: inout SelectionSpeechRouting, holds: Bool = true) -> [SelectionSpeechRouting.Action] {
    routing.press(key: .leftControl, action: .ask, holds: holds)
  }

  @Test("an ask key held past the delay opens the mic with the hand-back press")
  func askOpensMic() {
    var routing = SelectionSpeechRouting()
    #expect(ask(&routing) == [.readSelection, .startHoldTimer])
    _ = routing.selectionResolved("Revenue rose.")
    #expect(routing.holdElapsed() == [.forward(.pressHandingBack(key: nil))])
    #expect(routing.submit(.release) == [.forward(.release)])
  }

  @Test("a tapped ask key records until the next tap, like a dictation")
  func tappedAskLatches() {
    var routing = SelectionSpeechRouting()
    _ = ask(&routing, holds: false)
    _ = routing.selectionResolved("Revenue rose.")
    #expect(routing.keyLatched() == [.forward(.pressHandingBack(key: nil))])
    #expect(routing.submit(.release) == [.forward(.release)])
  }

  @Test("the transcript handed back is answered aloud, about the selection")
  func answers() {
    var routing = SelectionSpeechRouting()
    _ = ask(&routing)
    _ = routing.selectionResolved("Revenue rose.")
    _ = routing.holdElapsed()
    _ = routing.submit(.release)
    #expect(
      routing.sessionPhaseChanged(.handedBack("Summarize this."))
        == [.answer(request: "Summarize this.", selection: "Revenue rose.")])
    #expect(routing.speechFinished() == [.resetGate])
  }

  @Test("a press stops an answer: the dictation key then dictates, any other key's press is cleared")
  func pressStopsAnswer() {
    var routing = SelectionSpeechRouting()
    _ = ask(&routing)
    _ = routing.selectionResolved("Revenue rose.")
    _ = routing.holdElapsed()
    _ = routing.submit(.release)
    _ = routing.sessionPhaseChanged(.handedBack("Explain."))
    #expect(
      routing.press(key: .rightCommand, action: .dictate, holds: true)
        == [.stopSpeech, .forward(.press(key: .rightCommand))])
    #expect(ask(&routing) == [.readSelection, .startHoldTimer])
  }

  @Test("a held ask let go before the gate's threshold ends the request, rather than latching")
  func shortHeldAskEnds() {
    var routing = SelectionSpeechRouting()
    _ = ask(&routing)
    _ = routing.selectionResolved("Revenue rose.")
    _ = routing.holdElapsed()
    #expect(routing.keyLatched() == [.forward(.release), .resetGate])
    #expect(
      routing.sessionPhaseChanged(.handedBack("Summarize."))
        == [.answer(request: "Summarize.", selection: "Revenue rose.")])
  }

  @Test("a held ask let go before the selection read returns asks nothing, and frees the gate it latched")
  func shortHeldAskBeforeRead() {
    var routing = SelectionSpeechRouting()
    _ = ask(&routing)
    _ = routing.holdElapsed()
    #expect(routing.keyLatched() == [.resetGate])
    #expect(routing.selectionResolved("Revenue rose.").isEmpty)
    // Back to passthrough with the gate idle: the next press is a fresh one.
    #expect(ask(&routing) == [.readSelection, .startHoldTimer])
  }

  @Test("with nothing selected, a held ask let go before the read returns frees the gate once")
  func shortHeldAskNothingSelected() {
    var routing = SelectionSpeechRouting()
    _ = ask(&routing)
    _ = routing.holdElapsed()
    #expect(routing.keyLatched() == [.resetGate])
    #expect(routing.selectionResolved(nil).isEmpty)
  }

  @Test("the dictation key tapped while a let-go held ask's read is out dictates, whenever the read lands")
  func dictationAfterShortHeldAsk() {
    var routing = SelectionSpeechRouting()
    _ = ask(&routing)
    _ = routing.holdElapsed()
    _ = routing.keyLatched()
    #expect(
      routing.press(key: .rightCommand, action: .dictate, holds: true)
        == [.forward(.press(key: .rightCommand))])
    // The ask's read lands mid-dictation: it neither asks nor touches the gate.
    #expect(routing.selectionResolved("Revenue rose.").isEmpty)
    // The dictation key's own latch isn't taken for the ask's.
    #expect(routing.keyLatched().isEmpty)
    #expect(routing.submit(.release) == [.forward(.release)])
    #expect(routing.sessionPhaseChanged(.idle) == [.syncGateAfterSession])
  }

  @Test("a held ask let go past the gate's threshold, before the read returns, leaves the next press live")
  func longHeldAskBeforeRead() {
    var routing = SelectionSpeechRouting()
    _ = ask(&routing)
    _ = routing.holdElapsed()
    #expect(routing.submit(.release).isEmpty)
    #expect(
      routing.press(key: .rightCommand, action: .dictate, holds: true)
        == [.forward(.press(key: .rightCommand))])
    #expect(routing.selectionResolved("Revenue rose.").isEmpty)
  }

  @Test("a request with nothing said, or a failed one, is a dictation ending without a key event")
  func requestEndsQuietly() {
    for phase in [PipelinePhase.idle, .failed(.apiKeyMissing)] {
      var routing = SelectionSpeechRouting()
      _ = ask(&routing)
      _ = routing.selectionResolved("Revenue rose.")
      _ = routing.holdElapsed()
      _ = routing.submit(.release)
      #expect(routing.sessionPhaseChanged(phase) == [.syncGateAfterSession])
    }
  }

  @Test("the recording cap handing back with the key still down answers and clears the gate")
  func capHandsBack() {
    var routing = SelectionSpeechRouting()
    _ = ask(&routing)
    _ = routing.selectionResolved("Revenue rose.")
    _ = routing.holdElapsed()
    #expect(
      routing.sessionPhaseChanged(.handedBack("Explain."))
        == [.answer(request: "Explain.", selection: "Revenue rose."), .resetGate])
  }

  @Test("a combo while asking cancels the recording, as it would a dictation")
  func comboWhileAsking() {
    var routing = SelectionSpeechRouting()
    _ = ask(&routing)
    _ = routing.selectionResolved("Revenue rose.")
    _ = routing.holdElapsed()
    #expect(routing.submit(.cancel) == [.forward(.cancel)])
  }

  @Test("pressing again while the request is transcribing drops it and clears the new press")
  func pressWhileTranscribing() {
    var routing = SelectionSpeechRouting()
    _ = ask(&routing)
    _ = routing.selectionResolved("Revenue rose.")
    _ = routing.holdElapsed()
    _ = routing.submit(.release)
    #expect(ask(&routing) == [.forward(.cancel), .resetGate])
  }

  @Test("an ask while an earlier dictation finishes waits for it, then asks")
  func askWaitsForEarlierDictation() {
    var routing = SelectionSpeechRouting()
    _ = routing.sessionPhaseChanged(.transcribing)
    _ = ask(&routing)
    _ = routing.selectionResolved("Revenue rose.")
    #expect(routing.holdElapsed().isEmpty)
    #expect(routing.sessionPhaseChanged(.idle) == [.forward(.pressHandingBack(key: nil))])
  }

  @Test("an ask let go of before the earlier dictation finished asks nothing and cancels nothing")
  func askReleasedBeforeStart() {
    var routing = SelectionSpeechRouting()
    _ = routing.sessionPhaseChanged(.transcribing)
    _ = ask(&routing)
    _ = routing.selectionResolved("Revenue rose.")
    _ = routing.holdElapsed()
    #expect(routing.submit(.release).isEmpty)
    #expect(routing.sessionPhaseChanged(.idle).isEmpty)
    #expect(routing.sessionPhaseChanged(.idle) == [.syncGateAfterSession])
  }

  @Test("with nothing selected an ask key does nothing")
  func askNothingSelected() {
    var routing = SelectionSpeechRouting()
    _ = ask(&routing)
    #expect(routing.selectionResolved(nil) == [.resetGate])
    #expect(routing.holdElapsed().isEmpty)
  }
}
