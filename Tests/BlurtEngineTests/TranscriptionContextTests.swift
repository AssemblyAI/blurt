import Testing

@testable import AssemblyAI
@testable import BlurtAssemblyAI
@testable import BlurtEngine

/// `TranscriptionContext.isEmpty` is the gate `FocusCapture`/`DictationSession`
/// use to decide whether a captured context is worth carrying at all — it covers
/// every signal, including the ones that never leave the machine. It is *not* a
/// mirror of what gets sent: `STTPrompt.text` reads only
/// `recentTranscripts` and `priorText`, so the implication runs one way. An empty
/// context can never produce turns; a non-empty one often doesn't either.
@Suite("TranscriptionContext")
struct TranscriptionContextTests {
  /// One `isEmpty` expectation for a context built from the fields named.
  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    let context: TranscriptionContext
    let expectsEmpty: Bool
    var testDescription: String { name }
  }

  static let cases: [Case] = [
    Case(
      name: "both fields nil is empty",
      context: TranscriptionContext(appName: nil, priorText: nil),
      expectsEmpty: true
    ),
    Case(
      name: "whitespace-only fields are empty",
      context: TranscriptionContext(appName: "   ", priorText: "\n\t "),
      expectsEmpty: true
    ),
    Case(
      name: "a real app name makes it non-empty",
      context: TranscriptionContext(appName: "Slack", priorText: nil),
      expectsEmpty: false
    ),
    Case(
      name: "real prior text makes it non-empty",
      context: TranscriptionContext(appName: nil, priorText: "hello there"),
      expectsEmpty: false
    ),
    Case(
      name: "real selected text makes it non-empty",
      context: TranscriptionContext(appName: nil, priorText: nil, selectedText: "highlighted"),
      expectsEmpty: false
    ),
    Case(
      name: "whitespace-only selected text stays empty",
      context: TranscriptionContext(appName: nil, priorText: nil, selectedText: "  \n"),
      expectsEmpty: true
    ),
  ]

  @Test("isEmpty is false only when some field carries real text", arguments: cases)
  func isEmptyGate(_ c: Case) {
    #expect(c.context.isEmpty == c.expectsEmpty)
  }

  @Test("key terms alone make it non-empty, and ride their own field")
  func keyTermsPresent() {
    let context = TranscriptionContext(appName: nil, priorText: nil, keyTerms: ["Blurt"])
    #expect(!context.isEmpty)
    // Not in the context turns — they are sent as the request's word-boost list,
    // which is why a key-terms-only context is still worth carrying.
    #expect(STTPrompt.text(context: context).isEmpty)
    #expect(KeyTerms.fitted(context.keyTerms) == ["Blurt"])
  }

  @Test("recent dictations alone make it non-empty, and are what gets sent")
  func recentTranscriptsPresent() {
    // The history needs no focus signal at all to be worth carrying: dictating
    // into an app with no accessible field still sends the prior turns.
    let context = TranscriptionContext(
      appName: nil, priorText: nil, recentTranscripts: ["Said this before."]
    )
    #expect(!context.isEmpty)
    #expect(STTPrompt.text(context: context) == "Said this before.")
  }

  @Test("an empty context can never produce context turns")
  func emptyContextSendsNothing() {
    let empties = [
      TranscriptionContext(appName: nil, priorText: nil),
      TranscriptionContext(appName: "  ", priorText: "\n"),
    ]
    for context in empties {
      #expect(context.isEmpty)
      #expect(STTPrompt.text(context: context).isEmpty)
    }
  }

  @Test("a non-empty context still sends nothing without history or a prior chunk")
  func nonEmptyContextSendsOnlyHistoryAndPriorChunk() {
    // The converse of the rule above does not hold, and that is the whole point
    // of the narrowed context: these snapshots are worth capturing (paste spacing,
    // the developer-mode log) and carry nothing the request may have.
    let withoutSendable = [
      TranscriptionContext(appName: "Mail", priorText: nil),
      TranscriptionContext(appName: nil, priorText: nil, windowTitle: "Re: Q3 pricing"),
      TranscriptionContext(appName: nil, priorText: nil, selectedText: "selected"),
    ]
    for context in withoutSendable {
      #expect(!context.isEmpty)
      #expect(STTPrompt.text(context: context).isEmpty)
    }

    #expect(
      !STTPrompt.text(context: TranscriptionContext(appName: nil, priorText: "hello"))
        .isEmpty)
  }

  @Test("Equatable compares every field")
  func equatable() {
    let context = TranscriptionContext(appName: "Notes", priorText: "x")
    let sameContext = TranscriptionContext(appName: "Notes", priorText: "x")
    #expect(context == sameContext)
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
      TranscriptionContext(appName: "Notes", priorText: "x", windowTitle: "a")
        != TranscriptionContext(appName: "Notes", priorText: "x", windowTitle: "b"))
    #expect(
      TranscriptionContext(appName: "Notes", priorText: "x", fieldLabel: "To")
        != TranscriptionContext(appName: "Notes", priorText: "x", fieldLabel: "Subject"))
    #expect(
      TranscriptionContext(appName: "Notes", priorText: "x", keyTerms: ["a"])
        != TranscriptionContext(appName: "Notes", priorText: "x", keyTerms: ["b"]))
    #expect(
      TranscriptionContext(appName: "Notes", priorText: "x", recentTranscripts: ["a"])
        != TranscriptionContext(appName: "Notes", priorText: "x", recentTranscripts: ["b"]))
  }
}
