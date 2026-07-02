import Foundation
import Testing

@testable import BlurtEngine

/// The synchronous `submit(_:)` command feed — the seam callback-shaped hosts
/// (Blurt's CGEventTap) drive instead of spawning an unordered `Task` per
/// callback. These tests subscribe to the phase stream *before* submitting so
/// the fire-and-forget commands can be observed to completion.
@Suite("DictationSession submit", .timeLimit(.minutes(1)))
struct DictationSessionSubmitTests {

  @Test("submit runs press → release in emit order through the full pipeline")
  func submitHappyPath() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("Hello world."))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    let stream = await session.phaseStream()
    session.submit(.press)
    session.submit(.release)

    var seen: [PipelinePhase] = []
    for await phase in stream {
      seen.append(phase)
      // The initial yield is .idle (terminal); stop on the first terminal
      // phase the submitted commands produce.
      if phase.isTerminal && phase != .idle { break }
    }

    #expect(seen.contains(.recording))
    #expect(seen.last == .pasted)
    #expect(await injector.inserted == ["Hello world."])
  }

  @Test("submit(.cancel) after submit(.press) discards the capture in order")
  func submitCancelHonoredInOrder() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("never"))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    let stream = await session.phaseStream()
    // The exact shape of the race `submit` exists to prevent: were each of
    // these a separately spawned Task, the cancel could overtake the press,
    // no-op on a still-idle session, and strand the recording.
    session.submit(.press)
    session.submit(.cancel)

    for await phase in stream where phase == .cancelled { break }

    #expect(await session.phase == .cancelled)
    #expect(await mic.stopCalls == 1)
    #expect(await injector.inserted.isEmpty)
  }

  @Test("submit(.cancelRecording) tears down a live recording")
  func submitCancelRecording() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("never"))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    let stream = await session.phaseStream()
    session.submit(.press)
    session.submit(.cancelRecording)

    for await phase in stream where phase == .cancelled { break }

    #expect(await session.phase == .cancelled)
    #expect(await injector.inserted.isEmpty)
  }
}
