import Foundation
import Testing

@testable import BlurtEngine

@Suite("SelectionSpeechRouting")
struct SelectionSpeechRoutingTests {
  /// A read-aloud press: left ⌥, tap-only unless `holds`.
  private func read(_ routing: inout SelectionSpeechRouting, holds: Bool = false) -> [SelectionSpeechRouting.Action] {
    routing.press(key: .leftOption, action: .readAloud, holds: holds)
  }

  // MARK: - Dictation

  @Test("a dictating key's commands go straight to the session, with no selection read")
  func dictationPassesThrough() {
    var routing = SelectionSpeechRouting()
    #expect(routing.press(key: .rightOption, action: .dictate, holds: true) == [.forward(.press(key: .rightOption))])
    for command in [DictationSession.Command.release, .cancel, .cancelRecording] {
      #expect(routing.submit(command) == [.forward(command)])
    }
  }

  @Test("a key turned off mid-press dictates, as it was bound to")
  func offDictates() {
    var routing = SelectionSpeechRouting()
    #expect(routing.press(key: .function, action: .off, holds: false) == [.forward(.press(key: .function))])
  }

  @Test("a dictation's terminal phase syncs the gate only while commands go to the session")
  func terminalPhaseSync() {
    var routing = SelectionSpeechRouting()
    #expect(routing.sessionPhaseChanged(.idle) == [.syncGateAfterSession])
    _ = read(&routing)
    #expect(routing.sessionPhaseChanged(.idle).isEmpty)
    _ = routing.keyLatched()
    _ = routing.selectionResolved("Hi.")
    #expect(routing.sessionPhaseChanged(.idle).isEmpty)
  }

  // MARK: - Read aloud

  @Test("a tap reads the selection once the tap lands, freeing the gate; the next press stops it")
  func tapReads() {
    var routing = SelectionSpeechRouting()
    #expect(read(&routing) == [.readSelection])
    #expect(routing.selectionResolved("Hello there.").isEmpty)
    #expect(routing.keyLatched() == [.speak("Hello there."), .resetGate])
    // The read key's next press stops it and clears the gate that press armed.
    #expect(read(&routing) == [.stopSpeech, .resetGate])
    // That stop already moved on, so a late finish is nothing.
    #expect(routing.speechFinished().isEmpty)
  }

  @Test("pressing the dictation key during a tapped read stops it and dictates")
  func dictationKeyInterruptsRead() {
    var routing = SelectionSpeechRouting()
    _ = read(&routing)
    _ = routing.keyLatched()
    _ = routing.selectionResolved("Hello there.")
    #expect(
      routing.press(key: .rightCommand, action: .dictate, holds: true)
        == [.stopSpeech, .forward(.press(key: .rightCommand))])
    #expect(routing.submit(.release) == [.forward(.release)])
  }

  @Test("a tap that lands before the selection read returns still reads it")
  func tapBeforeRead() {
    var routing = SelectionSpeechRouting()
    _ = read(&routing)
    #expect(routing.keyLatched().isEmpty)
    #expect(routing.selectionResolved("Hello there.") == [.speak("Hello there."), .resetGate])
  }

  @Test("⌘C over a selection reads nothing, before or after the selection read returns")
  func comboReadsNothing() {
    var routing = SelectionSpeechRouting()
    _ = read(&routing)
    #expect(routing.submit(.cancel).isEmpty)
    #expect(routing.selectionResolved("Hello there.").isEmpty)

    _ = read(&routing)
    #expect(routing.selectionResolved("Hello there.").isEmpty)
    #expect(routing.submit(.cancel).isEmpty)
    #expect(routing.keyLatched().isEmpty)
    #expect(routing.press(key: .rightCommand, action: .dictate, holds: true) == [.forward(.press(key: .rightCommand))])
  }

  @Test("a holdable read key reads once held past the delay, and stops when let go")
  func holdReads() {
    var routing = SelectionSpeechRouting()
    #expect(read(&routing, holds: true) == [.readSelection, .startHoldTimer])
    _ = routing.selectionResolved("Hello there.")
    #expect(routing.holdElapsed() == [.speak("Hello there.")])
    #expect(routing.submit(.release) == [.stopSpeech])
  }

  @Test("a hold that outlasts a slow selection read reads as soon as the read returns")
  func holdBeforeRead() {
    var routing = SelectionSpeechRouting()
    _ = read(&routing, holds: true)
    #expect(routing.holdElapsed().isEmpty)
    #expect(routing.selectionResolved("Hello there.") == [.speak("Hello there.")])
  }

  @Test("let go of before the hold delay in hold-only mode, a read key does nothing")
  func quickReleaseUnderHold() {
    var routing = SelectionSpeechRouting()
    _ = read(&routing, holds: true)
    _ = routing.selectionResolved("Hello there.")
    #expect(routing.submit(.release).isEmpty)
    #expect(routing.holdElapsed().isEmpty)
  }

  @Test("a hold released before the gate's threshold keeps the read playing, and frees the gate")
  func shortHoldLatches() {
    var routing = SelectionSpeechRouting()
    _ = read(&routing, holds: true)
    _ = routing.selectionResolved("Hello there.")
    _ = routing.holdElapsed()
    #expect(routing.keyLatched() == [.resetGate])
    #expect(read(&routing, holds: true) == [.stopSpeech, .resetGate])
  }

  @Test("with nothing selected a read key does nothing, and clears the gate it holds")
  func nothingSelected() {
    var routing = SelectionSpeechRouting()
    _ = read(&routing)
    #expect(routing.selectionResolved(nil) == [.resetGate])
    // Already let go: the gate is idle, so there's nothing to clear.
    _ = read(&routing)
    _ = routing.submit(.release)
    #expect(routing.selectionResolved(nil).isEmpty)
  }

  @Test("a tapped twice before the selection read returns reads nothing")
  func doubleTapBeforeRead() {
    var routing = SelectionSpeechRouting()
    _ = read(&routing)
    _ = routing.keyLatched()
    _ = routing.submit(.release)
    #expect(routing.selectionResolved("Hello there.").isEmpty)
  }

  @Test("a read that ends on its own clears the gate silently")
  func readEndsOnItsOwn() {
    var routing = SelectionSpeechRouting()
    _ = read(&routing)
    _ = routing.keyLatched()
    _ = routing.selectionResolved("Hello there.")
    #expect(routing.speechFinished() == [.resetGate])
    #expect(routing.submit(.release) == [.forward(.release)])
  }

  @Test("a recovery reset while speaking stops the read and still reaches the session")
  func recoveryWhileSpeaking() {
    var routing = SelectionSpeechRouting()
    _ = read(&routing)
    _ = routing.keyLatched()
    _ = routing.selectionResolved("Hello there.")
    #expect(routing.submit(.cancelRecording) == [.stopSpeech, .forward(.cancelRecording)])
  }

  @Test("a stale selection result after the press resolved is ignored")
  func staleSelection() {
    var routing = SelectionSpeechRouting()
    _ = read(&routing)
    _ = routing.selectionResolved(nil)
    #expect(routing.selectionResolved("late").isEmpty)
  }
}

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

  @Test("a held ask let go before the selection read returns asks nothing")
  func shortHeldAskBeforeRead() {
    var routing = SelectionSpeechRouting()
    _ = ask(&routing)
    _ = routing.holdElapsed()
    _ = routing.keyLatched()
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
