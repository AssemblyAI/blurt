import Foundation
import Testing

@testable import BlurtEngine

/// `DictationSession`'s `onTranscriptDelivered` side channel. Split from
/// `DictationSessionTests` (same stubs) to stay within the lint file-length
/// budget.
@Suite("DictationSession transcript delivery", .timeLimit(.minutes(1)))
struct DictationSessionTranscriptTests {
  // The transcript callback is collected in a `StringListBox` (the shared
  // thread-safe recorder in `InjectorTestSupport`): it fires `@Sendable` on the
  // session's actor and is read after `waitForIdle()`, when the terminal phase
  // (and thus the synchronous callback that precedes it) has already happened.

  @Test("onTranscriptDelivered fires with the transcript on the pasted outcome")
  func transcriptDeliveredOnPaste() async throws {
    let spy = StringListBox()
    let session = makeSession(
      mode: .transcript("Hello world."), onTranscriptDelivered: { text, _ in spy.append(text) }
    ).session

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(await session.phase == .pasted)
    #expect(spy.values == ["Hello world."])
  }

  @Test("onTranscriptDelivered fires on the noTarget (copied) outcome")
  func transcriptDeliveredOnNoTarget() async throws {
    let spy = StringListBox()
    let fixture = makeSession(
      mode: .transcript("Copied text."), onTranscriptDelivered: { text, _ in spy.append(text) })
    await fixture.injector.setError(BlurtError.noEditableTarget)

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .noTarget)
    #expect(spy.values == ["Copied text."])
  }

  @Test("onTranscriptDelivered fires even when the paste hard-fails")
  func transcriptDeliveredWhenPasteFails() async throws {
    let spy = StringListBox()
    // A real injection failure (not the quiet .noTarget degrade): the phase ends
    // .failed, but the transcript was still produced, so it must be delivered —
    // every dictation that yields text lands in the "Recent" list.
    let fixture = makeSession(
      mode: .transcript("Spoken but unpasted."), onTranscriptDelivered: { text, _ in spy.append(text) })
    await fixture.injector.setError(BlurtError.accessibilityPermissionMissing)

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .failed(.accessibilityPermissionMissing))
    #expect(spy.values == ["Spoken but unpasted."])
  }

  @Test("onTranscriptDelivered hands over the ring the transcript just joined")
  func deliveryCarriesTheUpdatedRing() async throws {
    // The property the app's "Recent" list depends on: it assigns this value
    // wholesale rather than recording into a ring of its own, so the value must
    // already include the transcript being reported — and must be the same history
    // the *next* request's `conversation_context` is built from.
    // Each push recorded as its ring's contents joined, so the growth across two
    // dictations is one readable expectation (`StringListBox` is the existing
    // thread-safe recorder; the ring itself is asserted on the session below).
    let pushed = StringListBox()
    let fixture = makeSession(
      mode: .transcript("Hello world."),
      onTranscriptDelivered: { _, recents in
        pushed.append(recents.entries.map(\.text).joined(separator: " | "))
      })

    for _ in 1...2 {
      await fixture.session.press()
      await fixture.session.release()
      await fixture.session.waitForIdle()
    }

    // The first push already contains the transcript it reported — an empty ring
    // here would leave the "Recent" list one dictation behind forever.
    #expect(pushed.values == ["Hello world.", "Hello world. | Hello world."])
    // And what was pushed is the session's own history, not a copy built for the
    // callback: this is the same ring the next request's turns come from.
    #expect(await fixture.session.recentDictations.entries.count == 2)
  }

  @Test("onTranscriptDelivered does not fire when STT fails")
  func transcriptNotDeliveredOnFailure() async throws {
    struct Boom: Error {}
    let spy = StringListBox()
    let session = makeSession(mode: .throwError(Boom()), onTranscriptDelivered: { text, _ in spy.append(text) })
      .session

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(spy.values.isEmpty)
  }

  @Test("onTranscriptDelivered does not fire when the transcript is empty/whitespace")
  func transcriptNotDeliveredOnEmpty() async throws {
    let spy = StringListBox()
    // A normally-sized clip (StubMicCapture's default) so the too-short-clip
    // guard doesn't short-circuit before the transcribe step is reached.
    let session = makeSession(mode: .transcript("   "), onTranscriptDelivered: { text, _ in spy.append(text) })
      .session

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(await session.phase == .idle)
    #expect(spy.values.isEmpty)
  }

  @Test("onTranscriptDelivered does not fire when the dictation is cancelled")
  func transcriptNotDeliveredOnCancel() async throws {
    let spy = StringListBox()
    let session = makeSession(
      mode: .transcript("Hello world."), onTranscriptDelivered: { text, _ in spy.append(text) }
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
