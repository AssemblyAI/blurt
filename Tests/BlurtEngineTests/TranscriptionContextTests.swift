import Testing

@testable import BlurtEngine

/// `TranscriptionContext.isEmpty` is the gate `FocusCapture`/`DictationSession`
/// use to decide whether a captured context is worth carrying at all — it covers
/// every signal, including the ones that never leave the machine. It is *not* a
/// mirror of prompt emptiness: `TranscriptionPrompt.build` reads only
/// `priorText`, so the implication runs one way. An empty context can never
/// produce a prompt; a non-empty one usually doesn't either.
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
    // Not in the prompt — they are sent as the request's word-boost list, which
    // is why a key-terms-only context is still worth carrying.
    #expect(TranscriptionPrompt.build(context: context) == nil)
    #expect(KeytermsBoost.fitted(context.keyTerms) == ["Blurt"])
  }

  @Test("an empty context can never produce a prompt")
  func emptyContextSendsNothing() {
    let empties = [
      TranscriptionContext(appName: nil, priorText: nil),
      TranscriptionContext(appName: "  ", priorText: "\n"),
    ]
    for context in empties {
      #expect(context.isEmpty)
      #expect(TranscriptionPrompt.build(context: context) == nil)
    }
  }

  @Test("a non-empty context still sends nothing unless it has a prior chunk")
  func nonEmptyContextSendsOnlyThePriorChunk() {
    // The converse of the rule above does not hold, and that is the whole point
    // of the narrowed prompt: these contexts are worth capturing (paste spacing,
    // the developer-mode log) and carry nothing the request may have.
    let withoutPrior = [
      TranscriptionContext(appName: "Mail", priorText: nil),
      TranscriptionContext(appName: nil, windowTitle: "Re: Q3 pricing", priorText: nil),
      TranscriptionContext(appName: nil, priorText: nil, selectedText: "selected"),
    ]
    for context in withoutPrior {
      #expect(!context.isEmpty)
      #expect(TranscriptionPrompt.build(context: context) == nil)
    }

    #expect(TranscriptionPrompt.build(context: TranscriptionContext(appName: nil, priorText: "hello")) != nil)
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
  }
}
