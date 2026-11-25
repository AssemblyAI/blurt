import Foundation
import Testing

@testable import BlurtEngine

/// A press that can't tell whether its target is a password field — the read
/// never landed, or reached no focused element — is remembered for the Recent
/// list (which stays on this device) but never replayed in a later request's
/// `stt_prompt`, and its transcript is withheld from the developer-mode log.
/// The known-secure and ordinary cases are in `DictationSessionContextTests`.
@Suite("DictationSession unknown target security", .timeLimit(.minutes(1)))
struct DictationSessionUnknownSecurityTests {
  /// A password field, so a read that *did* land would refuse it outright —
  /// which is what makes "it never landed" the case under test.
  private static let secureField = FocusedFieldContext(
    priorText: nil,
    selectedText: nil,
    windowTitle: "1Password",
    fieldLabel: "Password",
    security: .secure
  )

  @Test("a dictation released before the read lands is kept in Recent but never replayed")
  func hungReadIsNotReplayed() async {
    // The other half of `lateSecureCaptureStillSuppressesHistory`: there the read lands before
    // the decision, here it never does. Not knowing whether the target is a
    // password field must not read as knowing it isn't — a nil `capturedContext`
    // used to, so a beachballing password prompt leaked into `stt_prompt`. It is
    // still remembered, because the Recent list and saved history stay local.
    let clock = TestClock()
    let transcriber = StubTranscriber(mode: .transcript("hunter2"))
    let injector = StubInjector()
    let log = RecordedLog()
    let (seams, hung) = hungFieldSeams(field: Self.secureField, log: log)
    let session = makeSession(
      transcriber: transcriber, injector: injector, clock: clock, seams: seams
    )

    await session.press()
    await session.release()
    await clock.waitUntilSleeping(for: DictationSession.contextWaitBudget)
    clock.advance(by: DictationSession.contextWaitBudget)
    await session.waitForIdle()

    // Delivered as always, and listed in Recent.
    #expect(await injector.inserted == ["hunter2"])
    #expect(await session.capturedContext == nil)
    #expect(await session.recentDictations.entries.map(\.text) == ["hunter2"])
    // But never offered as context to a later request.
    #expect(await session.recentDictations.spokenOldestFirst.isEmpty)
    // Nor written to the developer-mode log, which had no context to decide from.
    #expect(log.transcripts.map(\.text) == [DictationLog.unverifiedTranscript])
    hung.signal()  // release the capture thread before the test ends
  }

  @Test("a field Accessibility can't reach is kept in Recent but never replayed")
  func unreachableFieldIsNotReplayed() async {
    // `FocusCapture` reports `.unreachable` when no focused element answers — an
    // Electron app, whose login form is as invisible as its chat box. The flag
    // must survive the empty collapse, and the dictation must stay in Recent
    // without riding the next request's `stt_prompt`.
    #expect(FocusedFieldContext.unreachable.security == .unknown)
    #expect(FocusedFieldContext.empty.security == .ordinary)
    #expect(!TranscriptionContext(appName: nil, priorText: nil, targetSecurity: .unknown).isEmpty)
    #expect(TranscriptionContext(appName: nil, priorText: nil, targetSecurity: .ordinary).isEmpty)
    let fixture = makeSession(mode: .transcript("hunter2"), field: .unreachable)

    for _ in 1...2 {
      await fixture.session.dictate()
    }

    #expect(await fixture.injector.inserted == ["hunter2", "hunter2"])
    #expect(await fixture.session.recentDictations.entries.map(\.text) == ["hunter2", "hunter2"])
    let contexts = await fixture.transcriber.receivedContexts
    #expect(contexts.first??.targetSecurity == .unknown)
    // Dictation #2 went out with no history: #1 was never replayable.
    #expect(contexts.allSatisfy { $0?.recentTranscripts.isEmpty == true })
    #expect(contexts.allSatisfy { STTPrompt.text(context: $0).isEmpty })
    #expect(fixture.log.transcripts.map(\.text) == Array(repeating: DictationLog.unverifiedTranscript, count: 2))
  }

  @Test("a hand-back press over a field of unknown security logs its request withheld, as a dictation does")
  func handBackOverUnknownFieldIsWithheld() async {
    // The hand-back ending (read-aloud's "ask about the selection", the rewrite
    // and compose keys) returns before the paste, so it used to log the spoken
    // words verbatim where a pasted dictation into the same field is withheld.
    let fixture = makeSession(mode: .transcript("hunter2"), field: .unreachable)

    await fixture.session.dictate(handingBack: true)

    #expect(await fixture.session.phase == .handedBack("hunter2"))
    #expect(fixture.log.transcripts.map(\.text) == [DictationLog.unverifiedTranscript])
  }
}
