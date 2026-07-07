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
    let session = makeSession(
      mode: .transcript("Hello world."), onTranscriptDelivered: { spy.record($0) }
    ).session

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(await session.phase == .pasted)
    #expect(spy.values == ["Hello world."])
  }

  @Test("onTranscriptDelivered fires on the noTarget (copied) outcome")
  func transcriptDeliveredOnNoTarget() async throws {
    let spy = TranscriptSpy()
    let fixture = makeSession(
      mode: .transcript("Copied text."), onTranscriptDelivered: { spy.record($0) })
    await fixture.injector.setError(BlurtError.noEditableTarget)

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .noTarget)
    #expect(spy.values == ["Copied text."])
  }

  @Test("onTranscriptDelivered fires even when the paste hard-fails")
  func transcriptDeliveredWhenPasteFails() async throws {
    let spy = TranscriptSpy()
    // A real injection failure (not the quiet .noTarget degrade): the phase ends
    // .failed, but the transcript was still produced, so it must be delivered —
    // every dictation that yields text lands in the "Recent" list.
    let fixture = makeSession(
      mode: .transcript("Spoken but unpasted."), onTranscriptDelivered: { spy.record($0) })
    await fixture.injector.setError(BlurtError.accessibilityPermissionMissing)

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .failed(.accessibilityPermissionMissing))
    #expect(spy.values == ["Spoken but unpasted."])
  }

  @Test("onTranscriptDelivered does not fire when STT fails")
  func transcriptNotDeliveredOnFailure() async throws {
    struct Boom: Error {}
    let spy = TranscriptSpy()
    let session = makeSession(mode: .throwError(Boom()), onTranscriptDelivered: { spy.record($0) })
      .session

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(spy.values.isEmpty)
  }

  @Test("onTranscriptDelivered does not fire when the transcript is empty/whitespace")
  func transcriptNotDeliveredOnEmpty() async throws {
    let spy = TranscriptSpy()
    // A normally-sized clip (StubMicCapture's default) so the too-short-clip
    // guard doesn't short-circuit before the transcribe step is reached.
    let session = makeSession(mode: .transcript("   "), onTranscriptDelivered: { spy.record($0) })
      .session

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(await session.phase == .idle)
    #expect(spy.values.isEmpty)
  }

  @Test("onTranscriptDelivered does not fire when the dictation is cancelled")
  func transcriptNotDeliveredOnCancel() async throws {
    let spy = TranscriptSpy()
    let session = makeSession(
      mode: .transcript("Hello world."), onTranscriptDelivered: { spy.record($0) }
    ).session

    // Cancel while still recording, before release() can hand off to
    // transcribe/inject — mirrors `cancelDuringRecording` in
    // `DictationSessionTests.swift`, the deterministic way to drive `.cancelled`
    // without racing the transcribe step.
    await session.press()
    await session.cancel()

    #expect(await session.phase == .cancelled)
    #expect(spy.values.isEmpty)
  }
}
