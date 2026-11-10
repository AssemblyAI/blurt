import Testing

@testable import BlurtEngine

/// Escape from every routing mode: it stops the router's own work and cancels a
/// busy session, where a combo (`submit(.cancel)`) would be absorbed or miss one
/// of them.
@Suite("SelectionSpeechRouting · Escape")
struct SelectionSpeechRoutingEscapeTests {
  private func routing(_ mode: SelectionSpeechRouting.Mode, sessionBusy: Bool = false) -> SelectionSpeechRouting {
    var routing = SelectionSpeechRouting()
    _ = routing.sessionPhaseChanged(sessionBusy ? .transcribing : .idle)
    routing.mode = mode
    return routing
  }

  @Test("a plain dictation's cancel goes to the session, which decides by its own phase")
  func passthroughForwards() {
    var idle = routing(.passthrough)
    #expect(idle.escape() == [.forward(.cancel)])
    var busy = routing(.passthrough, sessionBusy: true)
    #expect(busy.escape() == [.forward(.cancel)])
  }

  @Test("a job or a spoken answer after a hand-back stops, and nothing is pasted")
  func stopsJobsAndSpeech() {
    var job = routing(.working)
    #expect(job.escape() == [.stopJob])
    #expect(!job.isBusy)
    var answer = routing(.speaking)
    #expect(answer.escape() == [.stopSpeech])
    #expect(!answer.isBusy)
  }

  @Test("speech over a dictation still in flight stops, and the dictation is cancelled too")
  func speakingOverABusySession() {
    var routing = routing(.speaking, sessionBusy: true)
    #expect(routing.escape() == [.stopSpeech, .forward(.cancel)])
  }

  @Test("a press still deciding is dropped, and doesn't absorb the busy dictation's cancel")
  func decidingOverABusySession() {
    var routing = routing(.deciding(.rewrite, trigger: nil, ended: false), sessionBusy: true)
    #expect(routing.escape() == [.forward(.cancel)])
    // Its selection read, still out, no longer decides anything.
    #expect(routing.selectionResolved("text").isEmpty)
    #expect(routing.mode == .passthrough)
  }

  @Test("a command not yet proven drops its prepared screen")
  func selectedCommand() {
    var routing = routing(.selected(.command, ""))
    #expect(routing.escape() == [.stopJob])
  }

  @Test("a request recording or transcribing is cancelled in the session")
  func requests() {
    var asking = routing(.asking(.rewrite, "sel", started: true, byHold: false), sessionBusy: true)
    #expect(asking.escape() == [.forward(.cancel)])
    var transcribing = routing(.transcribing(.command, "", started: true), sessionBusy: true)
    #expect(transcribing.escape() == [.forward(.cancel), .stopJob])
    // Unstarted, its press waits on an earlier dictation: Escape discards that one.
    var waiting = routing(.asking(.ask, "sel", started: false, byHold: true), sessionBusy: true)
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
