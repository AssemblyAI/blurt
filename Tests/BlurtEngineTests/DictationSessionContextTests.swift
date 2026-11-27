import Foundation
import Testing

@testable import BlurtAssemblyAI
@testable import BlurtEngine

/// What the session does with the context it captures at press time, and what it
/// records in the developer-mode log. Both used to be module-level statics
/// (`FocusCapture`, `DictationLog`), so the context's *value* was whatever app
/// happened to be frontmost during the run — assertable only as "one argument
/// arrived" — and the log went to the user's real `~/Library/Logs/Blurt`. Behind
/// the seams (`testSeams`) both are ordinary values.
@Suite("DictationSession captured context", .timeLimit(.minutes(1)))
struct DictationSessionContextTests {
  private static let field = FocusedFieldContext(
    priorText: "Hi Sam,",
    selectedText: "the old plan",
    windowTitle: "Re: Q3 pricing",
    fieldLabel: "Body",
    security: .ordinary
  )

  /// The secure-target fixture, shared by the two tests that assert a password
  /// is never remembered — one where the read lands in time, one where it lands
  /// after the upload's budget.
  private static let secureField = FocusedFieldContext(
    priorText: nil,
    selectedText: nil,
    windowTitle: "1Password",
    fieldLabel: "Password",
    security: .secure
  )

  @Test("the press-time capture reaches the transcriber, the injector, and the log")
  func contextThreadsThroughThePipeline() async {
    let fixture = makeSession(
      mode: .transcript("Hello world."),
      field: Self.field,
      frontmost: CapturedFocus(pid: 501, processName: "Mail"),
      keyTerms: ["AssemblyAI"]
    )

    await fixture.session.dictate()

    // One snapshot, assembled from the frontmost app, the field read, and the
    // key terms — and it must be the *same* one everywhere downstream, which is
    // why the session stores it rather than re-reading per consumer.
    let expected = TranscriptionContext(
      appName: "Mail",
      priorText: "Hi Sam,",
      windowTitle: "Re: Q3 pricing",
      fieldLabel: "Body",
      selectedText: "the old plan",
      keyTerms: ["AssemblyAI"]
    )
    #expect(await fixture.transcriber.receivedContexts == [expected])
    // The injector gets the two fields its separator decision runs on.
    #expect(await fixture.injector.insertedPrior == ["Hi Sam,"])
    #expect(await fixture.injector.insertedWindowTitles == ["Re: Q3 pricing"])
    // An ordinary field's words may stay on the clipboard as they are.
    #expect(await fixture.injector.insertedSecurity == [.ordinary])
    // Logged once the paste ended, with how it did.
    #expect(
      fixture.log.transcripts == [RecordedLog.Transcript(text: "Hello world.", context: expected, outcome: .pasted)])
  }

  @Test("a press's trigger key style rides its request and names its Recent row")
  func pressKeyStyleRidesTheDictation() async {
    let casual = PressStyle(instructions: "keep it breezy", name: "Casual")
    let fixture = makeSession(
      mode: .transcript("Hello world.")
    ) { $0 == .rightOption ? casual : PressStyle.base }

    await fixture.session.dictate(key: .rightOption)
    await fixture.session.dictate()

    // Resolved at each press from the key that pressed, so the second — no key,
    // the main window's (here, base) style — carries none of the first's.
    let contexts = await fixture.transcriber.receivedContexts
    #expect(contexts.map { $0?.styleInstructions } == ["keep it breezy", nil])
    #expect(await fixture.session.recentDictations.entries.map(\.style) == [nil, "Casual"])
  }

  @Test("an empty capture transcribes with no context rather than an empty one")
  func emptyCaptureYieldsNilContext() async {
    // `TranscriptionContext.isEmpty` collapses a capture with nothing usable in
    // it: passing the empty value on would put an empty turn list on the wire
    // instead of omitting the field.
    let fixture = makeSession(mode: .transcript("Hello world."))

    await fixture.session.dictate()

    #expect(await fixture.transcriber.receivedContexts == [nil])
    #expect(await fixture.injector.insertedPrior == [nil])
  }

  @Test("each press captures afresh, so a second dictation carries its own context")
  func eachPressCapturesAfresh() async {
    let fixture = makeSession(mode: .transcript("Second."), field: Self.field)

    await fixture.session.dictate()
    await fixture.session.dictate()

    // The stream the press installs is consumed once and cleared, so dictation #2
    // must not inherit — or be starved by — dictation #1's read.
    let contexts = await fixture.transcriber.receivedContexts
    #expect(contexts.count == 2)
    #expect(contexts.allSatisfy { $0?.priorText == "Hi Sam," })
  }

  @Test("each dictation becomes the next one's conversation-context history")
  func historyCarriesForward() async {
    let fixture = makeSession(mode: .transcript("First thought."), field: Self.field)

    for _ in 1...3 {
      await fixture.session.dictate()
    }

    let contexts = await fixture.transcriber.receivedContexts
    #expect(contexts.count == 3)
    // #1 had nothing to go on; #2 carries #1; #3 carries both, oldest first. The
    // repetition is the stub returning one fixed transcript, not the request
    // double-sending: the prior chunk here ("Hi Sam,") is a field the dictations
    // never landed in, so there is nothing to dedupe. The case where the chunk *is*
    // the last transcript is `dedupesHistoryAlreadyInThePriorChunk`.
    #expect(contexts[0]?.recentTranscripts.isEmpty == true)
    #expect(contexts[1]?.recentTranscripts == ["First thought."])
    #expect(contexts[2]?.recentTranscripts == ["First thought.", "First thought."])
    // And that history is what the wire prompt is built from, with the cursor's
    // prior chunk last — the whole point of accumulating it.
    #expect(
      STTPrompt.text(context: contexts[2])
        == "First thought.\nFirst thought.\nHi Sam,")
  }

  @Test("a dictation into a secure field is never remembered as history")
  func secureTargetIsNotRecorded() async {
    // The outgoing half of `FocusCapture`'s read guard. A password dictated into a
    // secure field must not become part of `stt_prompt` on every later
    // dictation — including in other apps — so it is transcribed, pasted, and
    // deliberately not recorded.
    let fixture = makeSession(mode: .transcript("hunter2"), field: Self.secureField)

    for _ in 1...2 {
      await fixture.session.dictate()
    }

    // It still reached the user: transcribed and pasted, twice.
    #expect(await fixture.injector.inserted == ["hunter2", "hunter2"])
    // But nothing was remembered, so dictation #2 carried no history and the ring
    // the "Recent" list projects stays empty.
    #expect(await fixture.session.recentDictations.entries.isEmpty)
    let contexts = await fixture.transcriber.receivedContexts
    #expect(contexts.allSatisfy { $0?.recentTranscripts.isEmpty == true })
    #expect(contexts.allSatisfy { STTPrompt.text(context: $0).isEmpty })
  }

  @Test("a missed budget still sends the key terms and the recent turns")
  func timedOutReadStillSendsPressKnownContext() async throws {
    // `pressKnown`'s reason to exist. Key terms and the recent-dictation ring
    // are read synchronously on the actor at press and need no AX round trip, so
    // a read that misses `contextWaitBudget` must cost the request only the
    // field text — not `keyterms_prompt` and the context turns along with it, which
    // is what happened when one `TranscriptionContext` carried all of it.
    let clock = TestClock()
    let transcriber = StubTranscriber(mode: .transcript("spoken"))
    let (seams, hung) = hungFieldSeams()
    let session = makeSession(
      transcriber: transcriber,
      injector: StubInjector(),
      clock: clock,
      keyTerms: ["Kubernetes"],
      seams: seams
    )

    // Twice, so the second press has history to carry — `recentDictations` is
    // actor state and this is how the sibling tests seed it. Each read is let
    // through only once its request has gone out unprimed, and before release:
    // a read still in flight at release is remembered but never replayed
    // (`DictationSessionUnknownSecurityTests`), and the first press has to be replayed.
    for press in 1...2 {
      await session.press()
      await clock.waitUntilSleeping(for: DictationSession.contextWaitBudget)
      clock.advance(by: DictationSession.contextWaitBudget)
      try await waitUntil("press \(press)'s request to go out") {
        await transcriber.receivedContexts.count >= press
      }
      hung.signal()
      try await waitUntil("press \(press)'s field to read as ordinary") {
        await session.pressContext?.targetSecurity == .ordinary
      }
      await session.release()
      await session.waitForIdle()
    }

    let contexts = await transcriber.receivedContexts
    #expect(contexts.count == 2)
    // Both requests carried the key terms despite neither read landing.
    #expect(contexts.allSatisfy { $0?.keyTerms == ["Kubernetes"] })
    // And the second carried the first's transcript as a context turn.
    let lastContext = contexts.last.flatMap(\.self)
    let second = try #require(lastContext)
    #expect(second.recentTranscripts == ["spoken"])
    #expect(STTPrompt.text(context: second) == "spoken")
    // None of the focus signals, which are the part that genuinely timed out.
    #expect(second.priorText == nil)
    #expect(second.windowTitle == nil)
  }

  @Test("a secure capture that lands after the upload's budget is still honored")
  func lateSecureCaptureStillSuppressesHistory() async throws {
    // The regression the config-first switch opened. `startUpload` cannot wait
    // past `contextWaitBudget` for the AX read without holding the audio back,
    // and that budget now runs against a read that has only had the mic
    // bring-up to finish in rather than the whole recording. A merely slow
    // target (Electron, Java, Office — `FocusCapture` makes ~6 serial round
    // trips, each capped at ~1 s) therefore misses it routinely.
    //
    // Missing it must not cost the `.secure` verdict, or the dictation
    // would be written into `recentDictations` and replayed in `stt_prompt` on
    // every later dictation this launch. `PressContext` is what keeps the read
    // reachable after the deadline, and this is the test that says so. (A read
    // that never lands at all is in `DictationSessionUnknownSecurityTests`.)
    let clock = TestClock()
    let transcriber = StubTranscriber(mode: .transcript("hunter2"))
    let injector = StubInjector()
    let (seams, gate) = hungFieldSeams(field: Self.secureField)
    let session = makeSession(
      transcriber: transcriber, injector: injector, clock: clock, seams: seams
    )

    await session.press()
    // Cross the upload's deadline while the capture is still blocked, so the
    // request goes out with no context at all — the case being tested.
    await clock.waitUntilSleeping(for: DictationSession.contextWaitBudget)
    clock.advance(by: DictationSession.contextWaitBudget)
    // `advance` only resumes the budget's sleeper; the upload's race is not
    // decided until that child runs. Wait for the request to actually open
    // before unblocking the read, or a fast capture queue can win the race and
    // the request goes out primed after all.
    try await waitUntil("the request to go out") { await !transcriber.receivedContexts.isEmpty }
    // Only now let the read finish. Waiting on the box rather than sleeping, so
    // this asserts the recovery instead of racing the capture queue.
    gate.signal()
    try await waitUntil("the press's context to resolve") { await session.pressContext?.resolved != nil }

    await session.release()
    await session.waitForIdle()

    // Pasted, as always — the flag suppresses remembering, never delivery.
    #expect(await injector.inserted == ["hunter2"])
    // …and the paste knows it is a secret, so a "Copied" leave-behind is
    // concealed rather than kept by a clipboard manager (#348).
    #expect(await injector.insertedSecurity == [.secure])
    // The request itself did go out unprimed; that is the cost of the deadline.
    #expect(await transcriber.receivedContexts == [nil])
    // But the late read was picked up in time for the decision that matters.
    #expect(await session.capturedContext?.targetSecurity == .secure)
    #expect(await session.recentDictations.entries.isEmpty)
  }

  @Test("a secure capture with no readable text is still carried, not collapsed to nil")
  func secureCaptureSurvivesTheEmptyCollapse() async {
    // `isEmpty` has to count `targetSecurity`: a secure field yields no prior or
    // selected text, so without that the snapshot would collapse to `nil` on the
    // way through `contextStream` and the guard above would never see the verdict.
    let secure = FocusedFieldContext(
      priorText: nil, selectedText: nil, windowTitle: nil, fieldLabel: nil, security: .secure
    )
    #expect(!TranscriptionContext(appName: nil, priorText: nil, targetSecurity: .secure).isEmpty)
    let fixture = makeSession(mode: .transcript("hunter2"), field: secure, frontmost: nil)

    await fixture.session.dictate()

    #expect(await fixture.transcriber.receivedContexts.first??.targetSecurity == .secure)
    #expect(await fixture.session.recentDictations.entries.isEmpty)
    #expect(await fixture.injector.insertedSecurity == [.secure])
  }

  @Test("history alone keeps the context worth carrying when the capture is empty")
  func historySurvivesAnEmptyCapture() async {
    // `emptyCaptureYieldsNilContext` above holds only until something has been
    // dictated: with no focus signal at all, the history is now the one thing that
    // makes the snapshot non-empty, and dropping it to nil would silently lose the
    // dialogue in exactly the apps that expose no accessible field.
    let fixture = makeSession(mode: .transcript("Said this."))

    for _ in 1...2 {
      await fixture.session.dictate()
    }

    let contexts = await fixture.transcriber.receivedContexts
    #expect(contexts.first == nil as TranscriptionContext?)
    #expect(contexts.last??.recentTranscripts == ["Said this."])
    #expect(STTPrompt.text(context: contexts[1]) == "Said this.")
  }

  /// The bounded wait, driven through the pipeline rather than against
  /// `firstValue` in isolation: a capture that never returns costs the transcript
  /// its priming and nothing else.
  @Test("a context read that never completes is abandoned once the budget elapses")
  func hungCaptureStillTranscribes() async {
    let clock = TestClock()
    let transcriber = StubTranscriber(mode: .transcript("Spoken anyway."))
    let injector = StubInjector()
    // Models a beachballing frontmost app: the capture blocks its Dispatch
    // thread for the whole test, so `PressContext` never resolves.
    let (seams, hung) = hungFieldSeams()
    let session = makeSession(
      transcriber: transcriber, injector: injector, clock: clock, seams: seams
    )

    await session.press()
    await session.release()
    // The pipeline is now parked on the context wait. Let the timeout racer
    // register with the virtual clock, then cross its deadline.
    await clock.waitUntilSleeping(for: DictationSession.contextWaitBudget)
    clock.advance(by: DictationSession.contextWaitBudget)
    await session.waitForIdle()

    #expect(await session.phase == .pasted)
    #expect(await injector.inserted == ["Spoken anyway."])
    // A read that never landed can't vouch for the field, so the paste is told
    // it doesn't know — not that the field is ordinary, which a nil
    // `capturedContext` used to read as.
    #expect(await injector.insertedSecurity == [.unknown])
    #expect(await transcriber.receivedContexts == [nil])
    hung.signal()  // release the capture thread before the test ends
  }

  @Test("a capture that reached no focused element tells the paste it doesn't know the field's security")
  func unreachableFieldIsUnknownToThePaste() async {
    let fixture = makeSession(mode: .transcript("maybe a password"), field: .unreachable, frontmost: nil)

    await fixture.session.dictate()

    #expect(await fixture.injector.inserted == ["maybe a password"])
    #expect(await fixture.injector.insertedSecurity == [.unknown])
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
      mic: mic,
      transcriber: StubTranscriber(mode: .transcript("never")),
      injector: StubInjector()
    )

    await session.press()
    #expect(await session.phase == .recording)
    await session.cancel()

    #expect(await session.phase == .cancelled)
    #expect(await mic.startCalls == 1)
  }
}
