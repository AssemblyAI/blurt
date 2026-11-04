import Testing

@testable import BlurtEngine

/// A command pressed while an earlier dictation still holds the session: what
/// it may forward before its own recording starts, and after.
@Suite("SelectionSpeechRouting · Busy session")
struct SelectionSpeechRoutingBusyTests {
  /// A held command pressed while a dictation transcribes: asking, unstarted.
  private func unstarted() -> SelectionSpeechRouting {
    var routing = SelectionSpeechRouting()
    _ = routing.sessionPhaseChanged(.transcribing)
    _ = routing.press(key: .rightOption, action: .command, holds: true)
    _ = routing.holdElapsed()
    return routing
  }

  @Test("a combo before the command's recording starts reaches no session; a recovery reset still does")
  func cancelWhileUnstarted() {
    var combo = unstarted()
    #expect(combo.submit(.cancel) == [.stopJob])
    var reset = unstarted()
    #expect(reset.submit(.cancelRecording) == [.forward(.cancelRecording), .stopJob])
  }

  @Test("once the earlier dictation ends the command's recording has started, so its release goes through")
  func startedOnceTheSessionFrees() {
    var routing = unstarted()
    #expect(routing.sessionPhaseChanged(.idle) == [.forward(.pressHandingBack(key: nil))])
    #expect(routing.submit(.release) == [.forward(.release), .readScreen])
  }
}
