import Testing

@testable import BlurtEngine

/// Escape from every routing mode: it stops the router's own work and cancels a
/// busy session, where a combo (`submit(.cancel)`) would be absorbed or miss one
/// of them.
@Suite("SelectionSpeechRouting · Escape")
struct SelectionSpeechRoutingEscapeTests {
  /// A held composition, its instructions spoken and handed back: the job is
  /// under way.
  private func working() -> SelectionSpeechRouting {
    var routing = SelectionSpeechRouting()
    _ = routing.press(key: .rightOption, action: .compose, holds: true)
    _ = routing.holdElapsed()
    _ = routing.submit(.release)
    _ = routing.sessionPhaseChanged(.handedBack("Say hi to Sam."))
    return routing
  }

  /// A tapped read over a selection: speaking.
  private func speaking() -> SelectionSpeechRouting {
    var routing = SelectionSpeechRouting()
    _ = routing.press(key: .leftOption, action: .readAloud, holds: false)
    _ = routing.keyLatched()
    _ = routing.selectionResolved("text")
    return routing
  }

  @Test("a plain dictation's cancel goes to the session, which decides by its own phase")
  func passthroughForwards() {
    var idle = SelectionSpeechRouting()
    #expect(!idle.isBusy)
    #expect(idle.escape() == [.forward(.cancel)])
    var busy = SelectionSpeechRouting()
    _ = busy.sessionPhaseChanged(.transcribing)
    #expect(busy.isBusy)
    #expect(busy.escape() == [.forward(.cancel)])
  }

  @Test("a job or a spoken answer after a hand-back stops, and nothing is pasted")
  func stopsJobsAndSpeech() {
    var job = working()
    #expect(job.isBusy)
    #expect(job.escape() == [.stopJob])
    #expect(!job.isBusy)
    // The stopped job's late end is nothing.
    #expect(job.jobFinished().isEmpty)
    var read = speaking()
    #expect(read.escape() == [.stopSpeech])
    #expect(read.speechFinished().isEmpty)
  }

  @Test("speech over a dictation still in flight stops, and the dictation is cancelled too")
  func speakingOverABusySession() {
    var routing = speaking()
    _ = routing.sessionPhaseChanged(.transcribing)
    #expect(routing.escape() == [.stopSpeech, .forward(.cancel)])
  }

  @Test("a press still deciding is dropped, and doesn't absorb the busy dictation's cancel")
  func decidingOverABusySession() {
    var routing = SelectionSpeechRouting()
    _ = routing.sessionPhaseChanged(.transcribing)
    _ = routing.press(key: .rightOption, action: .rewrite, holds: true)
    #expect(routing.escape() == [.forward(.cancel)])
    // Its selection read, still out, no longer decides anything.
    #expect(routing.selectionResolved("text").isEmpty)
    #expect(routing.holdElapsed().isEmpty)
  }

  @Test("a command not yet proven drops its prepared screen")
  func selectedCommand() {
    var routing = SelectionSpeechRouting()
    _ = routing.press(key: .rightOption, action: .command, holds: true)
    #expect(routing.escape() == [.stopJob])
  }

  @Test("a request recording or transcribing is cancelled in the session")
  func requests() {
    var asking = SelectionSpeechRouting()
    _ = asking.press(key: .rightOption, action: .rewrite, holds: true)
    _ = asking.selectionResolved("sel")
    _ = asking.holdElapsed()
    _ = asking.sessionPhaseChanged(.recording)
    #expect(asking.escape() == [.forward(.cancel)])

    var transcribing = SelectionSpeechRouting()
    _ = transcribing.press(key: .rightOption, action: .command, holds: true)
    _ = transcribing.holdElapsed()
    _ = transcribing.sessionPhaseChanged(.recording)
    _ = transcribing.submit(.release)
    #expect(transcribing.escape() == [.forward(.cancel), .stopJob])

    // Unstarted, its press waits on an earlier dictation: Escape discards that one.
    var waiting = SelectionSpeechRouting()
    _ = waiting.sessionPhaseChanged(.transcribing)
    _ = waiting.press(key: .rightOption, action: .ask, holds: true)
    _ = waiting.selectionResolved("sel")
    _ = waiting.holdElapsed()
    #expect(waiting.escape() == [.forward(.cancel)])
  }
}

/// The host's "something is in flight" can be a moment stale, so a cancel may
/// reach a session already at rest. It must change nothing there.
@Suite("DictationSession · stray cancel", .timeLimit(.minutes(1)))
struct DictationSessionStrayCancelTests {
  @Test("a cancel at rest leaves no standing request: the next press records")
  func cancelAtRestIsInert() async {
    let session = makeSession(transcriber: StubTranscriber(mode: .transcript("Hello world.")))
    await session.cancel()
    #expect(await session.phase == .idle)
    #expect(!session.cancelRequested)
    await session.press()
    #expect(await session.phase == .recording)
  }
}
