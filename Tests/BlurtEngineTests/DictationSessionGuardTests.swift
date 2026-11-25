import Foundation
import Testing

@testable import BlurtEngine

/// `DictationSession`'s reentrancy/no-op guards and phase-stream broadcast
/// contract. Split from `DictationSessionTests` (same stubs) to stay within the
/// lint file-length budget.
@Suite("DictationSession guards & phase stream", .timeLimit(.minutes(1)))
struct DictationSessionGuardTests {
  @Test("press while already recording is a silent no-op")
  func pressWhileRecordingDropped() async {
    let fixture = makeSession(mode: .transcript("hi"))

    await fixture.session.press()
    await fixture.session.press()  // .recording is non-terminal, so the guard drops this

    #expect(await fixture.mic.startCalls == 1)
    #expect(await fixture.session.phase == .recording)
  }

  @Test("release with nothing recording is a silent no-op")
  func releaseFromIdleNoOps() async {
    let fixture = makeSession(mode: .transcript("hi"))

    await fixture.session.release()

    #expect(await fixture.session.phase == .idle)
    #expect(await fixture.mic.stopCalls == 0)
  }

  @Test("cancel with nothing recording is a silent no-op")
  func cancelFromIdleNoOps() async {
    let fixture = makeSession(mode: .transcript("hi"))

    await fixture.session.cancel()

    #expect(await fixture.session.phase == .idle)
    #expect(await fixture.mic.stopCalls == 0)
  }

  @Test("keyTermsProvider is consulted afresh at each press")
  func keyTermsProviderReadPerPress() async {
    // The provider is a closure (not a stored list) precisely so Settings edits
    // take effect on the next dictation without rebuilding the session — that
    // only holds if every press re-reads it.
    let reads = Counter()
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("hi"))
    let injector = StubInjector()
    let session = makeSession(
      transcriber: stt,
      mic: mic,
      injector: injector
    ) {
      _ = reads.next()
      return ["Blurt"]
    }

    await session.press()
    await session.cancel()
    await session.press()
    await session.cancel()

    #expect(reads.value == 2)
  }

  @Test("multiple phaseStream subscribers all receive later transitions")
  func phaseStreamBroadcastsToMultipleSubscribers() async {
    let fixture = makeSession(mode: .transcript("hi"))

    // Subscribe while recording so each stream's initial yield is non-terminal.
    await fixture.session.press()
    let firstStream = await fixture.session.phaseStream()
    let secondStream = await fixture.session.phaseStream()

    func firstTerminal(_ stream: AsyncStream<PipelinePhase>) async -> PipelinePhase? {
      for await phase in stream where phase.isTerminal { return phase }
      return nil
    }
    async let firstTerminalPhase = firstTerminal(firstStream)
    async let secondTerminalPhase = firstTerminal(secondStream)
    await fixture.session.release()
    #expect(await firstTerminalPhase == .pasted)
    #expect(await secondTerminalPhase == .pasted)
  }

  /// #413: a coordinator subscribes from a task while it already takes
  /// commands, so a replayed opening `.idle` (terminal) could land after a
  /// press it accepted and end that dictation. Told what it already shows, the
  /// stream never queues that stale phase — but a phase the session moved to
  /// first still opens it, so nothing the host hasn't rendered is lost.
  @Test("phaseStream(alreadyShowing:) skips an opening phase the host already shows, never a newer one")
  func phaseStreamSkipsAShownOpeningPhase() async {
    let fixture = makeSession()

    let fresh = await fixture.session.phaseStream(alreadyShowing: .idle)
    fixture.session.submit(.press())
    var seen: [PipelinePhase] = []
    for await phase in fresh {
      seen.append(phase)
      if phase == .recording { break }
    }
    #expect(seen == [.connecting, .recording], "no stale .idle ahead of the press's own phases")

    // The session took the press before this subscriber caught up: it opens on it.
    var late = await fixture.session.phaseStream(alreadyShowing: .idle).makeAsyncIterator()
    let opening = await late.next()
    #expect(opening == .recording)

    await fixture.session.cancel()
  }
}
