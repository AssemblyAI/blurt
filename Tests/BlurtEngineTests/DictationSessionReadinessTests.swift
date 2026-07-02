import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// The press-time readiness check: a host-supplied blocker (Blurt passes a
/// key-presence check) refuses `press()` before any capture begins, so the user
/// never records an utterance the pipeline could only fail to transcribe.
@Suite("DictationSession readiness", .timeLimit(.minutes(1)))
struct DictationSessionReadinessTests {

  @Test("press is refused before capture when the readiness check blocks")
  func blockedPressFailsBeforeCapture() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("never"))
    let injector = StubInjector()
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector,
      readinessCheck: { .apiKeyMissing }
    )

    await session.press()

    #expect(await session.phase == .failed(.apiKeyMissing))
    // The whole point: the refusal lands before the mic ever starts.
    #expect(await mic.startCalls == 0)
  }

  @Test("press succeeds once the blocker clears")
  func pressRecoversWhenReady() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("Hello."))
    let injector = StubInjector()
    let ready = Mutex(false)
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector,
      readinessCheck: { ready.withLock { $0 } ? nil : .apiKeyMissing }
    )

    await session.press()
    #expect(await session.phase == .failed(.apiKeyMissing))

    // The user saves a key; `.failed` is terminal, so the next press runs.
    ready.withLock { $0 = true }
    await session.press()
    #expect(await session.phase == .recording)
    #expect(await mic.startCalls == 1)
  }
}
