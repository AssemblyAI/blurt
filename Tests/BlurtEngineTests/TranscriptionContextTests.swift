import Testing

@testable import BlurtEngine

/// `TranscriptionContext.isEmpty` is the gate `FocusCapture`/`DictationSession`
/// use to decide whether a captured context is worth carrying at all — it covers
/// every signal, including the ones that never leave the machine. It is *not* a
/// mirror of what gets sent: `ConversationContext.turns` reads only
/// `recentTranscripts` and `priorText`, so the implication runs one way. An empty
/// context can never produce turns; a non-empty one often doesn't either.
@Suite("TranscriptionContext")
struct TranscriptionContextTests {
  @Test("both fields nil is empty")
  func bothNil() {
    #expect(TranscriptionContext(appName: nil, priorText: nil).isEmpty)
  }

  @Test("whitespace-only fields are empty")
  func whitespaceOnly() {
    #expect(TranscriptionContext(appName: "   ", priorText: "\n\t ").isEmpty)
  }

  @Test("a real app name makes it non-empty")
  func appNamePresent() {
    #expect(!TranscriptionContext(appName: "Slack", priorText: nil).isEmpty)
  }

  @Test("real prior text makes it non-empty")
  func priorTextPresent() {
    #expect(!TranscriptionContext(appName: nil, priorText: "hello there").isEmpty)
  }

  @Test("real selected text makes it non-empty")
  func selectedTextPresent() {
    #expect(!TranscriptionContext(appName: nil, priorText: nil, selectedText: "highlighted").isEmpty)
  }

  @Test("whitespace-only selected text stays empty")
  func selectedTextWhitespace() {
    #expect(TranscriptionContext(appName: nil, priorText: nil, selectedText: "  \n").isEmpty)
  }

  @Test("key terms alone make it non-empty, and ride their own field")
  func keyTermsPresent() {
    let context = TranscriptionContext(appName: nil, priorText: nil, keyTerms: ["Blurt"])
    #expect(!context.isEmpty)
    // Not in the context turns — they are sent as the request's word-boost list,
    // which is why a key-terms-only context is still worth carrying.
    #expect(ConversationContext.turns(context: context).isEmpty)
    #expect(KeytermsBoost.fitted(context.keyTerms) == ["Blurt"])
  }

  @Test("recent dictations alone make it non-empty, and are what gets sent")
  func recentTranscriptsPresent() {
    // The history needs no focus signal at all to be worth carrying: dictating
    // into an app with no accessible field still sends the prior turns.
    let context = TranscriptionContext(
      appName: nil, priorText: nil, recentTranscripts: ["Said this before."])
    #expect(!context.isEmpty)
    #expect(ConversationContext.turns(context: context) == ["Said this before."])
  }

  @Test("an empty context can never produce context turns")
  func emptyContextSendsNothing() {
    let empties = [
      TranscriptionContext(appName: nil, priorText: nil),
      TranscriptionContext(appName: "  ", priorText: "\n"),
    ]
    for context in empties {
      #expect(context.isEmpty)
      #expect(ConversationContext.turns(context: context).isEmpty)
    }
  }

  @Test("a non-empty context still sends nothing without history or a prior chunk")
  func nonEmptyContextSendsOnlyHistoryAndPriorChunk() {
    // The converse of the rule above does not hold, and that is the whole point
    // of the narrowed context: these snapshots are worth capturing (paste spacing,
    // the developer-mode log) and carry nothing the request may have.
    let withoutSendable = [
      TranscriptionContext(appName: "Mail", priorText: nil),
      TranscriptionContext(appName: nil, windowTitle: "Re: Q3 pricing", priorText: nil),
      TranscriptionContext(appName: nil, priorText: nil, selectedText: "selected"),
    ]
    for context in withoutSendable {
      #expect(!context.isEmpty)
      #expect(ConversationContext.turns(context: context).isEmpty)
    }

    #expect(
      !ConversationContext.turns(context: TranscriptionContext(appName: nil, priorText: "hello"))
        .isEmpty)
  }

  @Test("Equatable compares every field")
  func equatable() {
    #expect(
      TranscriptionContext(appName: "Notes", priorText: "x")
        == TranscriptionContext(appName: "Notes", priorText: "x"))
    #expect(
      TranscriptionContext(appName: "Notes", priorText: "x")
        != TranscriptionContext(appName: "Notes", priorText: "y"))
    #expect(
      TranscriptionContext(appName: "Notes", priorText: nil)
        != TranscriptionContext(appName: nil, priorText: nil))
    #expect(
      TranscriptionContext(appName: "Notes", priorText: "x", selectedText: "a")
        != TranscriptionContext(appName: "Notes", priorText: "x", selectedText: "b"))
    #expect(
      TranscriptionContext(appName: "Notes", windowTitle: "a", priorText: "x")
        != TranscriptionContext(appName: "Notes", windowTitle: "b", priorText: "x"))
    #expect(
      TranscriptionContext(appName: "Notes", fieldLabel: "To", priorText: "x")
        != TranscriptionContext(appName: "Notes", fieldLabel: "Subject", priorText: "x"))
    #expect(
      TranscriptionContext(appName: "Notes", priorText: "x", keyTerms: ["a"])
        != TranscriptionContext(appName: "Notes", priorText: "x", keyTerms: ["b"]))
    #expect(
      TranscriptionContext(appName: "Notes", priorText: "x", recentTranscripts: ["a"])
        != TranscriptionContext(appName: "Notes", priorText: "x", recentTranscripts: ["b"]))
  }
}
