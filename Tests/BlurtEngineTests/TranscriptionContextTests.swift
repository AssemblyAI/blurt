import Testing

@testable import BlurtEngine

/// `TranscriptionContext.isEmpty` is the gate `FocusCapture`/`DictationSession`
/// use to decide whether a context is worth sending as priming. It mirrors the
/// emptiness logic in `TranscriptionPrompt.build`, so the two must agree:
/// `isEmpty == true` should always correspond to `build` returning `nil`.
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

  @Test("key terms alone make it non-empty (and produce a prompt)")
  func keyTermsPresent() {
    let context = TranscriptionContext(appName: nil, priorText: nil, keyTerms: ["Blurt"])
    #expect(!context.isEmpty)
    #expect(TranscriptionPrompt.build(context: context) != nil)
  }

  @Test("emptiness agrees with TranscriptionPrompt.build returning nil")
  func agreesWithPromptBuild() {
    let empties = [
      TranscriptionContext(appName: nil, priorText: nil),
      TranscriptionContext(appName: "  ", priorText: "\n"),
    ]
    for context in empties {
      #expect(context.isEmpty)
      #expect(TranscriptionPrompt.build(context: context) == nil)
    }

    let nonEmpties = [
      TranscriptionContext(appName: "Mail", priorText: nil),
      TranscriptionContext(appName: nil, priorText: nil, selectedText: "selected"),
    ]
    for context in nonEmpties {
      #expect(!context.isEmpty)
      #expect(TranscriptionPrompt.build(context: context) != nil)
    }
  }

  @Test("Equatable compares both fields")
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
  }
}
