import Foundation
import Testing

@testable import BlurtEngine

/// Which outcomes reach the developer-mode error log. The rule lives in
/// `setPhase` — every `.failed` route funnels through it, and the quiet outcomes
/// deliberately don't — and it had no test at all: the log suites cover the
/// writer, and the session wrote to the real one.
@Suite("DictationSession failure logging", .timeLimit(.minutes(1)))
struct DictationSessionFailureLogTests {
  @Test("a failure is logged once, with the captured context")
  func failureIsLogged() async {
    let fixture = makeSession(
      mode: .throwError(BlurtError.apiKeyMissing),
      field: FocusedFieldContext(
        priorText: nil, selectedText: nil, windowTitle: "Vault", fieldLabel: "Password", security: .ordinary
      )
    )

    await fixture.session.dictate()

    #expect(fixture.log.failureNames == ["apiKeyMissing"])
    #expect(fixture.log.failures.first?.context?.windowTitle == "Vault")
    // A dictation that failed produced no transcript to record.
    #expect(fixture.log.transcripts.isEmpty)
  }

  @Test("a press refused at the readiness check is logged before anything is captured")
  func refusedPressIsLogged() async {
    let mic = StubMicCapture()
    let log = RecordedLog()
    let session = makeSession(
      transcriber: StubTranscriber(mode: .transcript("never")),
      mic: mic,
      readinessCheck: { .apiKeyMissing },
      seams: testSeams(log: log)
    )

    await session.press()

    #expect(await session.phase == .failed(.apiKeyMissing))
    #expect(await mic.startCalls == 0)
    #expect(log.failureNames == ["apiKeyMissing"])
  }

  @Test("the quiet copied notice is not a failure, so nothing is logged")
  func noTargetIsNotLogged() async {
    // `.noTarget` is explicitly "don't report it": transcription worked, the
    // words just went to the clipboard. It must not show up in errors.jsonl.
    let fixture = makeSession(mode: .transcript("Copied text."))
    await fixture.injector.setError(BlurtError.noEditableTarget)

    await fixture.session.dictate()

    #expect(await fixture.session.phase == .noTarget)
    #expect(fixture.log.failures.isEmpty)
    // The transcript still counts — it was produced and left on the clipboard.
    #expect(fixture.log.transcripts.map(\.text) == ["Copied text."])
  }

  @Test("a cancelled dictation logs neither a failure nor a transcript")
  func cancelIsNotLogged() async {
    let fixture = makeSession(mode: .transcript("Hello world."))

    await fixture.session.press()
    await fixture.session.cancel()

    #expect(await fixture.session.phase == .cancelled)
    #expect(fixture.log.failures.isEmpty)
    #expect(fixture.log.transcripts.isEmpty)
  }

  /// The one route that logs *without* a phase change: a cancel whose `mic.stop()`
  /// fails must not flash red, but the fault can't just vanish either.
  @Test("a failing mic.stop during cancel is logged without repainting the phase")
  func failingCancelStopIsLoggedQuietly() async {
    let fixture = makeSession(mode: .transcript("Hello world."))
    await fixture.mic.setStopError(URLError(.unknown))

    await fixture.session.press()
    await fixture.session.cancel()

    #expect(await fixture.session.phase == .cancelled)
    #expect(fixture.log.failureNames == ["audioCaptureFailed"])
  }
}
