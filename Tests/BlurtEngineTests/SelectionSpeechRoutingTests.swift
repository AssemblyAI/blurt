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

  @Test("the dictation key pressed while a let-go read is still out dictates, and the read decides nothing")
  func dictationWhileEndedReadOut() {
    var routing = SelectionSpeechRouting()
    _ = read(&routing, holds: true)
    _ = routing.submit(.release)
    #expect(
      routing.press(key: .rightCommand, action: .dictate, holds: true)
        == [.forward(.press(key: .rightCommand))])
    #expect(routing.selectionResolved("Hello there.").isEmpty)
    #expect(routing.submit(.release) == [.forward(.release)])
  }

  @Test("a read pressed again while the last one's read is still out is decided by its own read")
  func repressWhileEndedReadOut() {
    var routing = SelectionSpeechRouting()
    _ = read(&routing)
    _ = routing.submit(.cancel)
    #expect(read(&routing) == [.readSelection])
    // The cancelled press's read lands first and is dropped, nil or not.
    #expect(routing.selectionResolved(nil).isEmpty)
    #expect(routing.selectionResolved("Hello there.").isEmpty)
    #expect(routing.keyLatched() == [.speak("Hello there."), .resetGate])
  }

  @Test("a stale selection result after the press resolved is ignored")
  func staleSelection() {
    var routing = SelectionSpeechRouting()
    _ = read(&routing)
    _ = routing.selectionResolved(nil)
    #expect(routing.selectionResolved("late").isEmpty)
  }
}
