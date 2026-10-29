import Foundation
import Testing

@testable import BlurtEngine

@Suite("SelectionSpeechRouting")
struct SelectionSpeechRoutingTests {
  @Test("with the switch off, every command goes straight to the session")
  func switchedOff() {
    var routing = SelectionSpeechRouting()
    for command in [DictationSession.Command.press(), .press(key: .rightOption), .release, .cancel, .cancelRecording] {
      #expect(routing.submit(command, readAloudEnabled: false) == [.forward(command)])
    }
  }

  @Test("a press with nothing selected dictates, replaying what arrived during the read in order")
  func noSelectionReplays() {
    var routing = SelectionSpeechRouting()
    #expect(routing.submit(.press(), readAloudEnabled: true) == [.readSelection])
    #expect(routing.submit(.release, readAloudEnabled: true).isEmpty)
    #expect(routing.selectionResolved(nil) == [.forward(.press()), .forward(.release)])
    #expect(routing.submit(.press(), readAloudEnabled: true) == [.readSelection])
  }

  @Test("a press with nothing selected dictates with its own trigger key")
  func noSelectionKeepsTheKey() {
    var routing = SelectionSpeechRouting()
    _ = routing.submit(.press(key: .rightOption), readAloudEnabled: true)
    #expect(routing.selectionResolved(nil) == [.forward(.press(key: .rightOption))])
  }

  @Test("a press over a selection speaks it, and the next key command stops it")
  func speaksThenStops() {
    var routing = SelectionSpeechRouting()
    _ = routing.submit(.press(), readAloudEnabled: true)
    #expect(routing.selectionResolved("Hello there.") == [.speak("Hello there.")])
    #expect(routing.submit(.release, readAloudEnabled: true) == [.stopSpeech])
    // The key stop already left the gate idle, so a late finish is nothing.
    #expect(routing.speechFinished().isEmpty)
  }

  @Test("a combo cancel during the read drops the press — ⌘C over a selection is a copy")
  func comboDuringRead() {
    var routing = SelectionSpeechRouting()
    _ = routing.submit(.press(), readAloudEnabled: true)
    _ = routing.submit(.cancel, readAloudEnabled: true)
    #expect(routing.selectionResolved("Hello there.").isEmpty)
    #expect(routing.submit(.press(), readAloudEnabled: false) == [.forward(.press())])
  }

  @Test("a recovery reset while speaking stops the read and still reaches the session")
  func recoveryWhileSpeaking() {
    var routing = SelectionSpeechRouting()
    _ = routing.submit(.press(), readAloudEnabled: true)
    _ = routing.selectionResolved("Hello there.")
    #expect(
      routing.submit(.cancelRecording, readAloudEnabled: true)
        == [.stopSpeech, .forward(.cancelRecording)])
  }

  @Test("a read that ends on its own clears the gate silently")
  func naturalEnd() {
    var routing = SelectionSpeechRouting()
    _ = routing.submit(.press(), readAloudEnabled: true)
    _ = routing.selectionResolved("Hello there.")
    #expect(routing.speechFinished() == [.resetGate])
    #expect(routing.submit(.press(), readAloudEnabled: false) == [.forward(.press())])
  }

  @Test("a dictation's terminal phase syncs the gate only while commands go to the session")
  func terminalPhaseOwnership() {
    var routing = SelectionSpeechRouting()
    #expect(routing.sessionPhaseChanged(.pasted) == [.syncGateAfterSession])
    _ = routing.submit(.press(), readAloudEnabled: true)
    #expect(routing.sessionPhaseChanged(.pasted).isEmpty)
    _ = routing.selectionResolved("Hello there.")
    // The earlier dictation finishing mid-read must not reset the read's gate.
    #expect(routing.sessionPhaseChanged(.pasted).isEmpty)
  }

  @Test("a press that lands during a slow read and is dropped clears the gate it latched")
  func pressDroppedDuringSlowRead() {
    var routing = SelectionSpeechRouting()
    _ = routing.submit(.press(), readAloudEnabled: true)
    // ⌘C over the selection, then a tap to read, all before an Electron app's
    // read returns. The tap latched the gate.
    _ = routing.submit(.cancel, readAloudEnabled: true)
    _ = routing.submit(.press(), readAloudEnabled: true)
    _ = routing.keyLatched()
    // Dropped like any press that was over before the read returned, but the
    // latch it left would swallow the next tap, so clear it.
    #expect(routing.selectionResolved("Hello there.") == [.resetGate])
    // A held-then-released press leaves the gate idle, so there is nothing to clear.
    _ = routing.submit(.press(), readAloudEnabled: true)
    _ = routing.submit(.release, readAloudEnabled: true)
    #expect(routing.selectionResolved("Hello there.").isEmpty)
  }

  @Test("a stale selection result after the press resolved is ignored")
  func staleResolution() {
    var routing = SelectionSpeechRouting()
    #expect(routing.selectionResolved("Hello there.").isEmpty)
  }
}

/// Asking about the selection: a hold over it records a spoken request, and the
/// answer is read aloud. A tap still reads the selection.
@Suite("SelectionSpeechRouting asking")
struct SelectionSpeechRoutingAskTests {
  private let selection = "The quarterly report."

  /// A routing that has pressed over `selection` with asking on, and resolved it
  /// while the key is still down.
  private func selected(_ start: SelectionSpeechRouting = SelectionSpeechRouting()) -> SelectionSpeechRouting {
    var routing = start
    _ = routing.submit(.press(), readAloudEnabled: true, askEnabled: true)
    _ = routing.selectionResolved(selection)
    return routing
  }

  /// A routing recording the spoken request.
  private func asking() -> SelectionSpeechRouting {
    var routing = selected()
    _ = routing.holdElapsed()
    return routing
  }

  @Test("a press that may ask starts the hold timer beside the selection read")
  func startsTimer() {
    var routing = SelectionSpeechRouting()
    #expect(routing.submit(.press(), readAloudEnabled: true, askEnabled: true) == [.readSelection, .startHoldTimer])
  }

  @Test("a tap over a selection reads it, without ever opening the mic")
  func tapReads() {
    var routing = selected()
    #expect(routing.keyLatched() == [.speak(selection)])
    // The read's key stop still works as before.
    #expect(routing.submit(.release, readAloudEnabled: true, askEnabled: true) == [.stopSpeech])
  }

  @Test("a tap that lands before the selection read returns still reads it")
  func tapDuringRead() {
    var routing = SelectionSpeechRouting()
    _ = routing.submit(.press(), readAloudEnabled: true, askEnabled: true)
    #expect(routing.keyLatched().isEmpty)
    #expect(routing.selectionResolved(selection) == [.speak(selection)])
  }

  @Test("a hold over a selection opens the mic with the hand-back press")
  func holdAsks() {
    var routing = selected()
    #expect(routing.holdElapsed() == [.forward(.pressHandingBack())])
  }

  @Test("the request about a selection is made with its trigger key's style")
  func askKeepsTheKey() {
    var routing = SelectionSpeechRouting()
    _ = routing.submit(.press(key: .rightOption), readAloudEnabled: true, askEnabled: true)
    #expect(routing.holdElapsed().isEmpty)
    #expect(routing.selectionResolved(selection) == [.forward(.pressHandingBack(key: .rightOption))])
  }

  @Test("a hold that outlasts a slow selection read asks as soon as the read returns")
  func holdDuringRead() {
    var routing = SelectionSpeechRouting()
    _ = routing.submit(.press(), readAloudEnabled: true, askEnabled: true)
    #expect(routing.holdElapsed().isEmpty)
    #expect(routing.selectionResolved(selection) == [.forward(.pressHandingBack())])
  }

  @Test("letting go after the gate's hold threshold releases the request")
  func longHoldReleases() {
    var routing = asking()
    #expect(routing.submit(.release, readAloudEnabled: true, askEnabled: true) == [.forward(.release)])
  }

  @Test("letting go before the gate's hold threshold also ends the request, and clears the latch")
  func shortHoldReleases() {
    var routing = asking()
    #expect(routing.keyLatched() == [.forward(.release), .resetGate])
  }

  @Test("the transcript handed back is answered aloud, about the selection")
  func answers() {
    var routing = asking()
    _ = routing.submit(.release, readAloudEnabled: true, askEnabled: true)
    #expect(
      routing.sessionPhaseChanged(.handedBack("Summarize this."))
        == [.answer(request: "Summarize this.", selection: selection)])
    // The answer is speech like any read: a key command stops it, and a natural
    // end clears the gate.
    #expect(routing.speechFinished() == [.resetGate])
  }

  @Test("a tap that stops an answer clears the gate it armed, so the next press isn't swallowed")
  func stopAnswerWithTap() {
    var routing = asking()
    _ = routing.submit(.release, readAloudEnabled: true, askEnabled: true)
    _ = routing.sessionPhaseChanged(.handedBack("Summarize this."))
    // The gate was idle under the answer, so the stopping tap arrives as a press.
    #expect(routing.submit(.press(), readAloudEnabled: true, askEnabled: true) == [.stopSpeech, .resetGate])
    // Its key-up latch then finds nothing to do, and the next press is a press.
    #expect(routing.keyLatched().isEmpty)
    #expect(routing.submit(.press(), readAloudEnabled: true, askEnabled: true) == [.readSelection, .startHoldTimer])
  }

  @Test("a request with nothing said reads the selection instead")
  func nothingSaid() {
    var routing = asking()
    _ = routing.submit(.release, readAloudEnabled: true, askEnabled: true)
    #expect(routing.sessionPhaseChanged(.idle) == [.speak(selection)])
  }

  @Test("a request that fails is a dictation ending without a key event")
  func failure() {
    var routing = asking()
    _ = routing.submit(.release, readAloudEnabled: true, askEnabled: true)
    let failed = PipelinePhase.failed(.sttFailed(underlying: URLError(.timedOut)))
    #expect(routing.sessionPhaseChanged(failed) == [.syncGateAfterSession])
    // Back to passthrough: the next press dictates or reads as usual.
    #expect(routing.submit(.press(), readAloudEnabled: false) == [.forward(.press())])
  }

  @Test("a recording that fails while the key is still down syncs the gate")
  func failureWhileHeld() {
    var routing = asking()
    let failed = PipelinePhase.failed(.audioCaptureFailed(underlying: URLError(.unknown)))
    #expect(routing.sessionPhaseChanged(failed) == [.syncGateAfterSession])
  }

  @Test("the recording cap handing back with the key still down answers and clears the gate")
  func handedBackWhileHeld() {
    var routing = asking()
    #expect(
      routing.sessionPhaseChanged(.handedBack("What is this?"))
        == [.answer(request: "What is this?", selection: selection), .resetGate])
  }

  @Test("a combo while asking cancels the recording, as it would a dictation")
  func comboWhileAsking() {
    var routing = asking()
    #expect(routing.submit(.cancel, readAloudEnabled: true, askEnabled: true) == [.forward(.cancel)])
  }

  @Test("pressing again while the request is transcribing drops it and clears the new press")
  func pressWhileTranscribing() {
    var routing = asking()
    _ = routing.submit(.release, readAloudEnabled: true, askEnabled: true)
    #expect(routing.submit(.press(), readAloudEnabled: true, askEnabled: true) == [.forward(.cancel), .resetGate])
    // A transcript arriving after that is someone else's now, and ignored.
    #expect(routing.sessionPhaseChanged(.cancelled) == [.syncGateAfterSession])
  }

  @Test("a hold while an earlier dictation finishes waits for it, then asks")
  func holdWaitsForEarlierDictation() {
    var routing = SelectionSpeechRouting()
    // The earlier dictation was let go of and is still being transcribed.
    _ = routing.sessionPhaseChanged(.transcribing)
    var held = selected(routing)
    // The session would refuse a press now, so none is sent yet...
    #expect(held.holdElapsed().isEmpty)
    // ...and the earlier dictation's end is not the request's: the mic opens now.
    #expect(held.sessionPhaseChanged(.pasted) == [.forward(.pressHandingBack())])
    #expect(held.sessionPhaseChanged(.recording).isEmpty)
    #expect(held.submit(.release, readAloudEnabled: true, askEnabled: true) == [.forward(.release)])
    #expect(
      held.sessionPhaseChanged(.handedBack("Summarize this."))
        == [.answer(request: "Summarize this.", selection: selection)])
  }

  @Test("a request let go of before the earlier dictation finished reads the selection, cancelling nothing")
  func releaseBeforeEarlierDictationEnds() {
    var routing = SelectionSpeechRouting()
    _ = routing.sessionPhaseChanged(.transcribing)
    var held = selected(routing)
    _ = held.holdElapsed()
    // Nothing goes to the session: it is still busy with the earlier dictation.
    #expect(held.submit(.release, readAloudEnabled: true, askEnabled: true).isEmpty)
    #expect(held.sessionPhaseChanged(.pasted) == [.speak(selection)])
  }

  @Test("a quick release before the hold delay, under a hold-only trigger, does nothing")
  func quickHoldOnlyRelease() {
    var routing = selected()
    #expect(routing.submit(.release, readAloudEnabled: true, askEnabled: true).isEmpty)
    #expect(routing.holdElapsed().isEmpty)
  }

  @Test("a hold timer is ignored outside a press that may ask")
  func staleTimer() {
    var routing = SelectionSpeechRouting()
    #expect(routing.holdElapsed().isEmpty)
    _ = routing.submit(.press(), readAloudEnabled: true, askEnabled: false)
    #expect(routing.holdElapsed().isEmpty)
    // Asking off reads at once, as before asking existed.
    #expect(routing.selectionResolved(selection) == [.speak(selection)])
  }

  @Test("with nothing selected, a press that may ask dictates as usual")
  func noSelection() {
    var routing = SelectionSpeechRouting()
    _ = routing.submit(.press(), readAloudEnabled: true, askEnabled: true)
    _ = routing.keyLatched()
    #expect(routing.selectionResolved(nil) == [.forward(.press())])
    #expect(routing.holdElapsed().isEmpty)
  }
}
