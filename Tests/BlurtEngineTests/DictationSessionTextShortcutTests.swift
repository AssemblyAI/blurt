import Foundation
import Testing

@testable import BlurtEngine

@Suite("DictationSession text shortcuts", .timeLimit(.minutes(1)))
struct DictationSessionTextShortcutTests {
  @Test("the pasted text and the delivered transcript are expanded; the log is not")
  func expandsBeforePaste() async {
    let spy = StringListBox()
    let fixture = makeSession(
      mode: .transcript("Mail personal email."),
      textShortcuts: [TextShortcut(trigger: "personal email", expansion: "me@example.com")],
      onTranscriptDelivered: spy.recordingDelivery
    )

    await fixture.session.dictate()

    #expect(await fixture.injector.inserted == ["Mail me@example.com."])
    #expect(spy.values == ["Mail me@example.com."])
    #expect(fixture.log.transcripts.map(\.text) == ["Mail personal email."])
  }

  /// The ring feeds the next request's `stt_prompt`, so it must carry what was
  /// said — a saved replacement (an address, a token) never goes on the wire —
  /// while the Recent row still shows what was pasted.
  @Test("the next request's history carries the spoken text, not the expansion")
  func historyStaysSpoken() async {
    let fixture = makeSession(
      mode: .transcript("Mail personal email."),
      textShortcuts: [TextShortcut(trigger: "personal email", expansion: "me@example.com")]
    )

    for _ in 1...2 {
      await fixture.session.dictate()
    }

    let contexts = await fixture.transcriber.receivedContexts
    #expect(contexts.last??.recentTranscripts == ["Mail personal email."])
    #expect(await fixture.session.recentDictations.entries.first?.text == "Mail me@example.com.")
  }

  /// The field holds what was pasted, so the next press reads the expansion
  /// back as `priorText` — which rides `stt_prompt` unless it is scrubbed. The
  /// context itself stays raw: the log and the paste separator read it.
  @Test("the text before the caret goes out with expansions put back to triggers")
  func priorTextRedacted() async {
    let fixture = makeSession(
      field: FocusedFieldContext(
        priorText: "Mail me@example.com.", selectedText: nil, windowTitle: nil, fieldLabel: nil, security: .ordinary
      ),
      textShortcuts: [TextShortcut(trigger: "personal email", expansion: "me@example.com")]
    )

    await fixture.session.dictate()

    let context = await fixture.transcriber.receivedContexts.last.flatMap(\.self)
    #expect(context?.priorText == "Mail me@example.com.")
    #expect(STTPrompt.text(context: context) == "Mail personal email.")
  }
}
