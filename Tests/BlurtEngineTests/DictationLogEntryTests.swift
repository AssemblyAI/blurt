import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtAssemblyAI
@testable import BlurtEngine

/// What one entry carries. These drive `makeEntry` and assert the value, because
/// every one of them is a question about the entry rather than about the file:
/// asked through `write` they needed a temp directory each, and the negative
/// cases ("no `selected` key", "no `turns` key") were substring searches that
/// passed just as happily when nothing had been written.
@Suite("DictationLog.makeEntry")
struct DictationLogEntryTests {
  private let context = TranscriptionContext(
    appName: "Mail",
    priorText: "Hi Sam,",
    windowTitle: "Re: Q3 pricing",
    fieldLabel: "Body",
    selectedText: "the old plan"
  )

  @Test("carries the transcript and an ISO-8601 timestamp")
  func transcriptAndTimestamp() {
    let entry = DictationLog.makeEntry(
      transcript: "Polished.", context: nil, now: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(entry.transcript == "Polished.")
    #expect(entry.ts.hasPrefix("2023-11-14"))
  }

  @Test("an entry names how the dictation ended, by the phase it ended in")
  func outcomeNames() {
    let names = [PipelinePhase.pasted, .noTarget, .handedBack("x"), .cancelled, .failed(.targetAppLost)]
      .map(DictationLog.outcomeName)
    #expect(names == ["pasted", "copied", "handed back", "cancelled", "failed: targetAppLost"])
    #expect(
      DictationLog.makeEntry(transcript: "p", context: nil, now: Date(), outcome: .noTarget).outcome == "copied")
  }

  @Test("a transcript dictated into a password field is withheld: the entry says so, and holds no word of it")
  func withholdsSecureTranscript() {
    let secure = TranscriptionContext(appName: "1Password", priorText: nil, targetSecurity: .secure)
    let entry = DictationLog.makeEntry(transcript: "hunter2 correct horse", context: secure, now: Date())
    #expect(entry.transcript == DictationLog.withheldTranscript)
    #expect(entry.app == "1Password")
    #expect(DictationLog.makeEntry(transcript: "hunter2", context: context, now: Date()).transcript == "hunter2")
  }

  @Test("threads every focus-context field, including the selected text")
  func threadsContext() {
    let entry = DictationLog.makeEntry(transcript: "p", context: context, now: Date())
    #expect(entry.app == "Mail")
    #expect(entry.window == "Re: Q3 pricing")
    #expect(entry.field == "Body")
    #expect(entry.prior == "Hi Sam,")
    #expect(entry.selected == "the old plan")
  }

  @Test("leaves every context field nil when nothing was captured")
  func noContextLeavesFieldsNil() {
    let entry = DictationLog.makeEntry(transcript: "p", context: nil, now: Date())
    #expect(entry.app == nil)
    #expect(entry.window == nil)
    #expect(entry.field == nil)
    #expect(entry.prior == nil)
    #expect(entry.selected == nil)
    #expect(entry.sttPrompt.isEmpty)
    #expect(entry.keyterms.isEmpty)
  }

  @Test("logs the contextual prompt the transcriber reports sending, in order")
  func logsWhatTheRequestCarries() {
    let withHistory = TranscriptionContext(
      appName: "Mail",
      priorText: "Hi Sam,",
      windowTitle: "Re: Q3 pricing",
      fieldLabel: "Body",
      selectedText: "the old plan",
      recentTranscripts: ["Sent the deck over."]
    )
    let sent = AssemblyAITranscriber().contextPrompt(for: withHistory)
    let entry = DictationLog.makeEntry(transcript: "p", context: withHistory, contextPrompt: sent, now: Date())
    // The entry records what the transcriber reports, rather than rebuilding it.
    #expect(entry.sttPrompt == sent)
    // So the logged prompt shows the narrowing too: the history and the prior chunk
    // went on the wire, the window title and the selected text did not — even
    // though the entry's own fields record all three.
    #expect(entry.sttPrompt == "Sent the deck over.\nHi Sam,")
    #expect(!entry.sttPrompt.contains("Re: Q3 pricing"))
    #expect(!entry.sttPrompt.contains("the old plan"))
  }

  @Test("keeps the prior chunk raw, where the prompt carrying it is trimmed")
  func priorIsRawWhereTheTurnIsTrimmed() {
    // Why `prior` isn't redundant with the prompt's tail. The trailing space is the
    // whole input to the paste's leading-separator decision
    // (`InsertionSeparator.withLeadingSeparator` branches on `prior.last.isWhitespace`),
    // and the wire copy has it trimmed off — so dropping `prior` for being a
    // duplicate would take the only record of that bit with it.
    let context = TranscriptionContext(appName: "Mail", priorText: "Hi Sam, ")
    let entry = DictationLog.makeEntry(
      transcript: "p",
      context: context,
      contextPrompt: STTPrompt.text(context: context),
      now: Date()
    )
    #expect(entry.prior == "Hi Sam, ")
    #expect(entry.sttPrompt == "Hi Sam,")
    #expect(InsertionSeparator.withLeadingSeparator("p", after: entry.prior) == "p")
    #expect(InsertionSeparator.withLeadingSeparator("p", after: entry.sttPrompt) == " p")
  }

  @Test("a nil prior tells a history-only prompt apart from a prior chunk")
  func nilPriorDisambiguatesTheLastTurn() {
    // The other half: the prompt's last line is a recent dictation here, not text
    // at the caret, and only `prior == nil` says so.
    let context = TranscriptionContext(appName: "Mail", priorText: nil, recentTranscripts: ["Said this before."])
    let entry = DictationLog.makeEntry(
      transcript: "p", context: context, contextPrompt: STTPrompt.text(context: context), now: Date()
    )
    #expect(entry.prior == nil)
    #expect(entry.sttPrompt == "Said this before.")
  }

  @Test("records the key terms the request boosts, cleaned the same way")
  func logsTheKeytermsTheRequestCarries() {
    // Through `KeyTermList.normalized`, not the raw list: a blank entry the
    // request would never carry is dropped here too.
    let withTerms = TranscriptionContext(
      appName: "Mail", priorText: "Hi Sam,", keyTerms: ["AssemblyAI", "  ", "LeMUR"]
    )
    let entry = DictationLog.makeEntry(transcript: "p", context: withTerms, now: Date())
    #expect(entry.keyterms == ["AssemblyAI", "LeMUR"])
  }

  @Test("records which rewrite model was asked for, Fast included, and none with the rewrite off")
  func logsTheRewriteMode() {
    func logged(_ mode: RewriteMode?) -> String? {
      DictationLog.makeEntry(transcript: "p", context: nil, now: Date(), rewriteMode: mode).rewriteMode
    }
    #expect(logged(.smart) == "smart")
    #expect(logged(.fast) == "fast")
    #expect(logged(nil) == nil)
  }

  @Test("leaves the key terms empty when the context has none")
  func noKeytermsLeavesTheFieldEmpty() {
    #expect(DictationLog.makeEntry(transcript: "p", context: context, now: Date()).keyterms.isEmpty)
  }

  @Test("keeps a transcript verbatim, including non-ASCII")
  func unicodeKeptVerbatim() {
    let transcript = "Café — 北京 🎙️."
    #expect(DictationLog.makeEntry(transcript: transcript, context: nil, now: Date()).transcript == transcript)
  }
}
