import Foundation
import Testing

@testable import BlurtEngine

/// `DictationSession`'s `onTranscriptDelivered` side channel. Split from
/// `DictationSessionTests` (same stubs) to stay within the lint file-length
/// budget.
@Suite("DictationSession transcript delivery", .timeLimit(.minutes(1)))
struct DictationSessionTranscriptTests {
  /// Thread-safe collector for the `@Sendable` transcript callback, which fires
  /// on the session's actor. Read after `waitForIdle()`, when the terminal phase
  /// (and thus the synchronous callback that precedes it) has already happened.
  private final class TranscriptSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func record(_ value: String) {
      lock.lock()
      defer { lock.unlock() }
      storage.append(value)
    }
    var values: [String] {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
  }

  @Test("onTranscriptDelivered fires with the transcript on the pasted outcome")
  func transcriptDeliveredOnPaste() async throws {
    let spy = TranscriptSpy()
    let session = DictationSession(
      mic: StubMicCapture(),
      transcriber: StubTranscriber(mode: .transcript("Hello world.")),
      injector: StubInjector(),
      onTranscriptDelivered: { spy.record($0) }
    )

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(await session.phase == .pasted)
    #expect(spy.values == ["Hello world."])
  }

  @Test("onTranscriptDelivered fires on the noTarget (copied) outcome")
  func transcriptDeliveredOnNoTarget() async throws {
    let spy = TranscriptSpy()
    let injector = StubInjector()
    await injector.setError(BlurtError.noEditableTarget)
    let session = DictationSession(
      mic: StubMicCapture(),
      transcriber: StubTranscriber(mode: .transcript("Copied text.")),
      injector: injector,
      onTranscriptDelivered: { spy.record($0) }
    )

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(await session.phase == .noTarget)
    #expect(spy.values == ["Copied text."])
  }

  @Test("onTranscriptDelivered does not fire when STT fails")
  func transcriptNotDeliveredOnFailure() async throws {
    struct Boom: Error {}
    let spy = TranscriptSpy()
    let session = DictationSession(
      mic: StubMicCapture(),
      transcriber: StubTranscriber(mode: .throwError(Boom())),
      injector: StubInjector(),
      onTranscriptDelivered: { spy.record($0) }
    )

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(spy.values.isEmpty)
  }
}
