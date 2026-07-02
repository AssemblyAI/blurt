import Foundation
import Testing

@testable import BlurtEngine

/// `DictationSession`'s reentrancy/no-op guards and the phase-stream
/// supersession contract. Split from `DictationSessionTests` (same stubs) to
/// stay within the lint file-length budget.
@Suite("DictationSession guards & phase stream", .timeLimit(.minutes(1)))
struct DictationSessionGuardTests {

  @Test("press while already recording is a silent no-op")
  func pressWhileRecordingDropped() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("hi"))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    await session.press()
    await session.press()  // .recording is non-terminal, so the guard drops this

    #expect(await mic.startCalls == 1)
    #expect(await session.phase == .recording)
  }

  @Test("release with nothing recording is a silent no-op")
  func releaseFromIdleNoOps() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("hi"))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    await session.release()

    #expect(await session.phase == .idle)
    #expect(await mic.stopCalls == 0)
  }

  @Test("cancel with nothing recording is a silent no-op")
  func cancelFromIdleNoOps() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("hi"))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    await session.cancel()

    #expect(await session.phase == .idle)
    #expect(await mic.stopCalls == 0)
  }

  @Test("keyTermsProvider is consulted afresh at each press")
  func keyTermsProviderReadPerPress() async throws {
    // The provider is a closure (not a stored list) precisely so Settings edits
    // take effect on the next dictation without rebuilding the session — that
    // only holds if every press re-reads it.
    let reads = Counter()
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("hi"))
    let injector = StubInjector()
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector,
      keyTermsProvider: {
        _ = reads.next()
        return ["Blurt"]
      })

    await session.press()
    await session.cancel()
    await session.press()
    await session.cancel()

    #expect(reads.value == 2)
  }

  @Test("a new phaseStream supersedes the prior one without severing delivery")
  func phaseStreamSupersession() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("hi"))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    // Subscribe while recording so each stream's initial yield is non-terminal.
    await session.press()
    let superseded = await session.phaseStream()
    let live = await session.phaseStream()

    // The superseded stream was finished by the newer subscription: it delivers
    // the phase it saw at subscription time and then ends.
    var seen: [PipelinePhase] = []
    for await phase in superseded { seen.append(phase) }
    #expect(seen == [.recording])

    // Draining the superseded stream fires its onTermination cleanup — give it
    // a chance to run so the identity guard (not timing) is what protects the
    // live continuation from being cleared by the stale teardown.
    for _ in 0..<1000 { await Task.yield() }

    func firstTerminal(_ stream: AsyncStream<PipelinePhase>) async -> PipelinePhase? {
      for await phase in stream where phase.isTerminal { return phase }
      return nil
    }
    async let terminal = firstTerminal(live)
    await session.release()
    #expect(await terminal == .pasted)
  }
}
