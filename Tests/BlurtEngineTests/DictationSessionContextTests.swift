import Foundation
import Testing

@testable import BlurtEngine

/// What the session does with the context it captures at press time, and what it
/// records in the developer-mode log. Both used to be module-level statics
/// (`FocusCapture`, `DictationLog`), so the context's *value* was whatever app
/// happened to be frontmost during the run — assertable only as "one argument
/// arrived" — and the log went to the user's real `~/Library/Logs/Blurt`. Behind
/// the seams (`testSeams`) both are ordinary values.
@Suite("DictationSession captured context", .timeLimit(.minutes(1)))
struct DictationSessionContextTests {
  private static let field = FocusCapture.FocusedFieldContext(
    priorText: "Hi Sam,", selectedText: "the old plan", windowTitle: "Re: Q3 pricing",
    fieldLabel: "Body")

  @Test("the press-time capture reaches the transcriber, the injector, and the log")
  func contextThreadsThroughThePipeline() async throws {
    let fixture = makeSession(
      mode: .transcript("Hello world."),
      field: Self.field,
      frontmost: CapturedFocus(pid: 501, processName: "Mail"),
      keyTerms: ["AssemblyAI"])

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    // One snapshot, assembled from the frontmost app, the field read, and the
    // key terms — and it must be the *same* one everywhere downstream, which is
    // why the session stores it rather than re-reading per consumer.
    let expected = TranscriptionContext(
      appName: "Mail", windowTitle: "Re: Q3 pricing", fieldLabel: "Body",
      priorText: "Hi Sam,", selectedText: "the old plan", keyTerms: ["AssemblyAI"])
    #expect(await fixture.transcriber.receivedContexts == [expected])
    // The injector gets the two fields its separator decision runs on.
    #expect(await fixture.injector.insertedPrior == ["Hi Sam,"])
    #expect(await fixture.injector.insertedWindowTitles == ["Re: Q3 pricing"])
    #expect(fixture.log.transcripts == [RecordedLog.Transcript(text: "Hello world.", context: expected)])
  }

  @Test("an empty capture transcribes with no context rather than an empty one")
  func emptyCaptureYieldsNilContext() async throws {
    // `TranscriptionContext.isEmpty` collapses a capture with nothing usable in
    // it: passing the empty value on would put an empty turn list on the wire
    // instead of omitting the field.
    let fixture = makeSession(mode: .transcript("Hello world."))

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.transcriber.receivedContexts == [nil])
    #expect(await fixture.injector.insertedPrior == [nil])
  }

  @Test("each press captures afresh, so a second dictation carries its own context")
  func eachPressCapturesAfresh() async throws {
    let fixture = makeSession(mode: .transcript("Second."), field: Self.field)

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()
    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    // The stream the press installs is consumed once and cleared, so dictation #2
    // must not inherit — or be starved by — dictation #1's read.
    let contexts = await fixture.transcriber.receivedContexts
    #expect(contexts.count == 2)
    #expect(contexts.allSatisfy { $0?.priorText == "Hi Sam," })
  }

  @Test("each dictation becomes the next one's conversation-context history")
  func historyCarriesForward() async throws {
    let fixture = makeSession(mode: .transcript("First thought."), field: Self.field)

    for _ in 1...3 {
      await fixture.session.press()
      await fixture.session.release()
      await fixture.session.waitForIdle()
    }

    let contexts = await fixture.transcriber.receivedContexts
    #expect(contexts.count == 3)
    // #1 had nothing to go on; #2 carries #1; #3 carries both, oldest first. The
    // repetition is the stub returning one fixed transcript, not the request
    // double-sending: the prior chunk here ("Hi Sam,") is a field the dictations
    // never landed in, so there is nothing to dedupe. The case where the chunk *is*
    // the last transcript is `dedupesHistoryAlreadyInThePriorChunk`.
    #expect(contexts[0]?.recentTranscripts == [])
    #expect(contexts[1]?.recentTranscripts == ["First thought."])
    #expect(contexts[2]?.recentTranscripts == ["First thought.", "First thought."])
    // And that history is what the wire turns are built from, with the cursor's
    // prior chunk last — the whole point of accumulating it.
    #expect(
      ConversationContext.turns(context: contexts[2])
        == ["First thought.", "First thought.", "Hi Sam,"])
  }

  @Test("a dictation into a secure field is never remembered as history")
  func secureTargetIsNotRecorded() async throws {
    // The outgoing half of `FocusCapture`'s read guard. A password dictated into a
    // secure field must not become a `conversation_context` turn on every later
    // dictation — including in other apps — so it is transcribed, pasted, and
    // deliberately not recorded.
    let secure = FocusCapture.FocusedFieldContext(
      priorText: nil, selectedText: nil, windowTitle: "1Password", fieldLabel: "Password",
      isSecure: true)
    let fixture = makeSession(mode: .transcript("hunter2"), field: secure)

    for _ in 1...2 {
      await fixture.session.press()
      await fixture.session.release()
      await fixture.session.waitForIdle()
    }

    // It still reached the user: transcribed and pasted, twice.
    #expect(await fixture.injector.inserted == ["hunter2", "hunter2"])
    // But nothing was remembered, so dictation #2 carried no history and the ring
    // the "Recent" list projects stays empty.
    #expect(await fixture.session.recentDictations.entries.isEmpty)
    let contexts = await fixture.transcriber.receivedContexts
    #expect(contexts.allSatisfy { $0?.recentTranscripts.isEmpty == true })
    #expect(contexts.allSatisfy { ConversationContext.turns(context: $0).isEmpty })
  }

  @Test("a secure capture with no readable text is still carried, not collapsed to nil")
  func secureCaptureSurvivesTheEmptyCollapse() async throws {
    // `isEmpty` has to count `targetIsSecure`: a secure field yields no prior or
    // selected text, so without that the snapshot would collapse to `nil` on the
    // way through `contextStream` and the guard above would never see the flag.
    let secure = FocusCapture.FocusedFieldContext(
      priorText: nil, selectedText: nil, windowTitle: nil, fieldLabel: nil, isSecure: true)
    #expect(!TranscriptionContext(appName: nil, priorText: nil, targetIsSecure: true).isEmpty)
    let fixture = makeSession(mode: .transcript("hunter2"), field: secure, frontmost: nil)

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.transcriber.receivedContexts.first??.targetIsSecure == true)
    #expect(await fixture.session.recentDictations.entries.isEmpty)
  }

  @Test("history alone keeps the context worth carrying when the capture is empty")
  func historySurvivesAnEmptyCapture() async throws {
    // `emptyCaptureYieldsNilContext` above holds only until something has been
    // dictated: with no focus signal at all, the history is now the one thing that
    // makes the snapshot non-empty, and dropping it to nil would silently lose the
    // dialogue in exactly the apps that expose no accessible field.
    let fixture = makeSession(mode: .transcript("Said this."))

    for _ in 1...2 {
      await fixture.session.press()
      await fixture.session.release()
      await fixture.session.waitForIdle()
    }

    let contexts = await fixture.transcriber.receivedContexts
    #expect(contexts.first == nil as TranscriptionContext?)
    #expect(contexts.last??.recentTranscripts == ["Said this."])
    #expect(ConversationContext.turns(context: contexts[1]) == ["Said this."])
  }

  /// The bounded wait, driven through the pipeline rather than against
  /// `firstValue` in isolation: a capture that never returns costs the transcript
  /// its priming and nothing else.
  @Test("a context read that never completes is abandoned once the budget elapses")
  func hungCaptureStillTranscribes() async throws {
    let clock = TestClock()
    let mic = StubMicCapture()
    let transcriber = StubTranscriber(mode: .transcript("Spoken anyway."))
    let injector = StubInjector()
    // Models a beachballing frontmost app: the capture blocks its Dispatch thread
    // for the whole test, so the stream behind `contextStream` never yields.
    let hung = DispatchSemaphore(value: 0)
    let session = DictationSession(
      mic: mic, transcriber: transcriber, injector: injector, clock: clock,
      keyTermsProvider: { [] },
      seams: DictationSession.Seams(
        captureFrontmost: { nil },
        captureFieldContext: {
          hung.wait()
          return .empty
        },
        logTranscript: { _, _ in },
        logFailure: { _, _ in }))

    await session.press()
    await session.release()
    // The pipeline is now parked on the context wait. Let the timeout racer
    // register with the virtual clock, then cross its deadline.
    await clock.waitUntilSleeping(for: DictationSession.contextWaitBudget)
    clock.advance(by: DictationSession.contextWaitBudget)
    await session.waitForIdle()

    #expect(await session.phase == .pasted)
    #expect(await injector.inserted == ["Spoken anyway."])
    #expect(await transcriber.receivedContexts == [nil])
    hung.signal()  // release the capture thread before the test ends
  }

  /// The one case that runs `Seams.production`, so the closures the app actually
  /// executes can't rot behind the injected ones. A smoke test by necessity: the
  /// real capture reads whatever is frontmost on the test host, so there is
  /// nothing to assert about its *value* — which is the whole reason the rest of
  /// this suite injects it.
  ///
  /// Press-then-cancel deliberately: no transcript is produced and no failure
  /// occurs, so the production log seams are composed without writing a line to
  /// the user's real `~/Library/Logs/Blurt`.
  @Test("the public initializer composes the production seams")
  func productionSeamsCompose() async {
    let mic = StubMicCapture()
    let session = DictationSession(
      mic: mic, transcriber: StubTranscriber(mode: .transcript("never")),
      injector: StubInjector())

    await session.press()
    #expect(await session.phase == .recording)
    await session.cancel()

    #expect(await session.phase == .cancelled)
    #expect(await mic.startCalls == 1)
  }
}

/// Which outcomes reach the developer-mode error log. The rule lives in
/// `setPhase` — every `.failed` route funnels through it, and the quiet outcomes
/// deliberately don't — and it had no test at all: the log suites cover the
/// writer, and the session wrote to the real one.
@Suite("DictationSession failure logging", .timeLimit(.minutes(1)))
struct DictationSessionFailureLogTests {
  @Test("a failure is logged once, with the captured context")
  func failureIsLogged() async throws {
    let fixture = makeSession(
      mode: .throwError(BlurtError.apiKeyMissing),
      field: FocusCapture.FocusedFieldContext(
        priorText: nil, selectedText: nil, windowTitle: "Vault", fieldLabel: "Password"))

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(fixture.log.failureNames == ["apiKeyMissing"])
    #expect(fixture.log.failures.first?.context?.windowTitle == "Vault")
    // A dictation that failed produced no transcript to record.
    #expect(fixture.log.transcripts.isEmpty)
  }

  @Test("a press refused at the readiness check is logged before anything is captured")
  func refusedPressIsLogged() async throws {
    let mic = StubMicCapture()
    let log = RecordedLog()
    let session = DictationSession(
      mic: mic, transcriber: StubTranscriber(mode: .transcript("never")),
      injector: StubInjector(), keyTermsProvider: { [] },
      readinessCheck: { .apiKeyMissing },
      seams: testSeams(log: log))

    await session.press()

    #expect(await session.phase == .failed(.apiKeyMissing))
    #expect(await mic.startCalls == 0)
    #expect(log.failureNames == ["apiKeyMissing"])
  }

  @Test("the quiet copied notice is not a failure, so nothing is logged")
  func noTargetIsNotLogged() async throws {
    // `.noTarget` is explicitly "don't report it": transcription worked, the
    // words just went to the clipboard. It must not show up in errors.jsonl.
    let fixture = makeSession(mode: .transcript("Copied text."))
    await fixture.injector.setError(BlurtError.noEditableTarget)

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .noTarget)
    #expect(fixture.log.failures.isEmpty)
    // The transcript still counts — it was produced and left on the clipboard.
    #expect(fixture.log.transcripts.map(\.text) == ["Copied text."])
  }

  @Test("a cancelled dictation logs neither a failure nor a transcript")
  func cancelIsNotLogged() async throws {
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
  func failingCancelStopIsLoggedQuietly() async throws {
    let fixture = makeSession(mode: .transcript("Hello world."))
    await fixture.mic.setStopError(URLError(.unknown))

    await fixture.session.press()
    await fixture.session.cancel()

    #expect(await fixture.session.phase == .cancelled)
    #expect(fixture.log.failureNames == ["audioCaptureFailed"])
  }
}
