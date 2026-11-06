import Testing

@testable import BlurtEngine

@Suite("SelectionSpeechRouting · Compose")
struct SelectionSpeechRoutingComposeTests {
  /// A compose press: right ⌥, holdable unless told otherwise.
  private func compose(_ routing: inout SelectionSpeechRouting, holds: Bool = true) -> [SelectionSpeechRouting.Action] {
    routing.press(key: .rightOption, action: .compose, holds: holds)
  }

  /// A held compose press, its instructions recorded and let go.
  private func spoken(_ routing: inout SelectionSpeechRouting) {
    _ = compose(&routing)
    _ = routing.holdElapsed()
    _ = routing.submit(.release)
  }

  @Test("a compose press reads no selection, and records once it proves itself by a tap or a hold")
  func recordsWithoutSelection() {
    var tapped = SelectionSpeechRouting()
    #expect(compose(&tapped, holds: false).isEmpty)
    #expect(tapped.keyLatched() == [.forward(.pressHandingBack(key: nil))])

    var held = SelectionSpeechRouting()
    #expect(compose(&held) == [.startHoldTimer])
    #expect(held.holdElapsed() == [.forward(.pressHandingBack(key: nil))])
  }

  @Test("let go or a combo before the press proves itself: nothing recorded")
  func unprovenPressDoesNothing() {
    var routing = SelectionSpeechRouting()
    _ = compose(&routing)
    #expect(routing.submit(.cancel).isEmpty)
    #expect(routing.holdElapsed().isEmpty)
  }

  @Test("the instructions handed back are composed, with no command preparation, and the end frees the gate")
  func composes() {
    var routing = SelectionSpeechRouting()
    spoken(&routing)
    #expect(routing.sessionPhaseChanged(.handedBack("Tell Dan hi.")) == [.compose(request: "Tell Dan hi.")])
    #expect(routing.speechFinished().isEmpty)
    #expect(routing.jobFinished() == [.resetGate])
  }

  @Test("a compose shows as Writing from the press until it's handed back")
  func processingState() {
    var routing = SelectionSpeechRouting()
    _ = compose(&routing)
    _ = routing.holdElapsed()
    #expect(routing.processingState == .composing)
    _ = routing.submit(.release)
    #expect(routing.processingState == .composing)
    _ = routing.sessionPhaseChanged(.handedBack("Tell Dan hi."))
    #expect(routing.processingState == nil)
  }

  @Test("a press abandons a composition before it pastes: the dictation key then dictates, any other is cleared")
  func pressAbandons() {
    let presses: [(press: (TriggerKey, TriggerKeyAction), expected: [SelectionSpeechRouting.Action])] = [
      ((.rightCommand, .dictate), [.stopJob, .forward(.press(key: .rightCommand))]),
      ((.rightOption, .compose), [.stopJob, .resetGate]),
    ]
    for ((key, action), expected) in presses {
      var routing = SelectionSpeechRouting()
      spoken(&routing)
      _ = routing.sessionPhaseChanged(.handedBack("Tell Dan hi."))
      #expect(routing.press(key: key, action: action, holds: true) == expected)
      // The router stopped it, so its late end is nothing.
      #expect(routing.jobFinished().isEmpty)
    }
  }

  @Test("nothing said: the press ends like a dictation, with no job to stop")
  func nothingSaid() {
    var routing = SelectionSpeechRouting()
    spoken(&routing)
    #expect(routing.sessionPhaseChanged(.idle) == [.syncGateAfterSession])
  }
}
