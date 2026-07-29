import Testing

@testable import BlurtEngine

/// `TranscriptionContext.isEmpty` is the gate `FocusCapture`/`DictationSession`
/// use to decide whether a context is worth carrying at all (steering AND log).
/// The agreement with `TranscriptionSteering.build` is one-directional:
/// `isEmpty == true` must always correspond to empty steering fields, while a
/// non-empty context may still steer nothing — its signals can be carry-only
/// (app name, field label, or selected text from an unrecognized app).
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

  @Test("a bundle ID alone makes it non-empty (and produces a rewrite instruction)")
  func bundleIDPresent() {
    let context = TranscriptionContext(appName: nil, bundleID: "com.apple.Terminal", priorText: nil)
    #expect(!context.isEmpty)
    #expect(TranscriptionSteering.build(context: context).rewriteInstruction != nil)
  }

  @Test("real selected text makes it non-empty")
  func selectedTextPresent() {
    #expect(!TranscriptionContext(appName: nil, priorText: nil, selectedText: "highlighted").isEmpty)
  }

  @Test("whitespace-only selected text stays empty")
  func selectedTextWhitespace() {
    #expect(TranscriptionContext(appName: nil, priorText: nil, selectedText: "  \n").isEmpty)
  }

  @Test("key terms alone make it non-empty (and produce keyterms)")
  func keyTermsPresent() {
    let context = TranscriptionContext(appName: nil, priorText: nil, keyTerms: ["Blurt"])
    #expect(!context.isEmpty)
    #expect(TranscriptionSteering.build(context: context).keyterms == ["Blurt"])
  }

  @Test("an empty context always corresponds to empty steering fields")
  func agreesWithSteeringBuild() {
    let empties = [
      TranscriptionContext(appName: nil, priorText: nil),
      TranscriptionContext(appName: "  ", priorText: "\n"),
    ]
    for context in empties {
      #expect(context.isEmpty)
      #expect(TranscriptionSteering.build(context: context).isEmpty)
    }

    // Renderable signals (a recognized bundle ID, key terms, prior text) each
    // steer at least one field…
    let renderable = [
      TranscriptionContext(appName: nil, bundleID: "com.apple.Terminal", priorText: nil),
      TranscriptionContext(appName: nil, priorText: nil, keyTerms: ["Blurt"]),
      TranscriptionContext(appName: nil, priorText: "Hi Sam,"),
    ]
    for context in renderable {
      #expect(!context.isEmpty)
      #expect(!TranscriptionSteering.build(context: context).isEmpty)
    }

    // …while carry-only signals make the context non-empty (worth carrying for
    // the injector) yet steer nothing. Selected text is the interesting one: the
    // paste replaces it, so it is never priming.
    let carryOnly = TranscriptionContext(appName: "Mail", priorText: nil, selectedText: "sel")
    #expect(!carryOnly.isEmpty)
    #expect(TranscriptionSteering.build(context: carryOnly).isEmpty)
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
      TranscriptionContext(appName: "Notes", bundleID: "com.a.b", priorText: "x")
        != TranscriptionContext(appName: "Notes", bundleID: "com.c.d", priorText: "x"))
  }
}
