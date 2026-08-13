import Testing

@testable import BlurtEngine

/// The context→prompt contract. `build` reads exactly one field of the context —
/// `priorText` — so these cases are as much about what the prompt *omits* as
/// what it carries; the scope suite below pins the omissions signal by signal.
@Suite("TranscriptionPrompt")
struct TranscriptionPromptTests {
  /// The standing plain-text exclusion clause that every built prompt carries
  /// (see `TranscriptionPrompt.baseInstruction`). Kept here as the single source
  /// of truth so the expectations below read clearly.
  static let base =
    "Transcribe without speaker labels, audio event descriptions, or emotion markers."

  /// One `build(context:)` → prompt expectation. Parameterizing these (rather
  /// than a `@Test` apiece) keeps the whole context→prompt contract in one
  /// readable table and gives per-case failure output.
  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    let context: TranscriptionContext?
    let expected: String?
    var testDescription: String { name }
  }

  static let cases: [Case] = [
    Case(name: "nil context → no prompt (server default)", context: nil, expected: nil),
    Case(
      name: "empty context → no prompt",
      context: TranscriptionContext(appName: nil, priorText: nil), expected: nil),
    Case(
      name: "whitespace-only prior text → no prompt",
      context: TranscriptionContext(appName: nil, priorText: "  \n\t"), expected: nil),
    Case(
      name: "prior text → Previous transcript framing",
      context: TranscriptionContext(appName: nil, priorText: "and then the build finished"),
      expected: "Previous transcript:\nand then the build finished\n\n\(base)"),
    Case(
      name: "prior text is trimmed",
      context: TranscriptionContext(appName: nil, priorText: "  hello  "),
      expected: "Previous transcript:\nhello\n\n\(base)"),
    Case(
      name: "newlines inside the prior chunk are preserved",
      context: TranscriptionContext(appName: nil, priorText: "Dear Sam,\n\nthanks for"),
      expected: "Previous transcript:\nDear Sam,\n\nthanks for\n\n\(base)"),
    Case(
      name: "every other signal, no prior text → no prompt",
      context: TranscriptionContext(
        appName: "Slack", windowTitle: "#eng-backend", fieldLabel: "Message",
        priorText: nil, selectedText: "the draft", keyTerms: ["Blurt"]),
      expected: nil),
  ]

  @Test("build maps the prior chunk to the transcription prompt", arguments: cases)
  func build(_ c: Case) {
    #expect(TranscriptionPrompt.build(context: c.context) == c.expected)
  }

  @Test("an over-long prior chunk is clipped to the cap, keeping the tail")
  func clipsPriorTextToCap() throws {
    // `FocusCapture` clips far shorter than this, but the cap is enforced here
    // rather than assumed of the caller — over the cap the API rejects the whole
    // request. The *tail* is what survives: the utterance continues from the text
    // nearest the cursor, so the oldest end is the part worth losing.
    let longPrior = String(repeating: "word ", count: 2000)
    let prompt = try #require(
      TranscriptionPrompt.build(context: TranscriptionContext(appName: nil, priorText: longPrior)))
    #expect(prompt.count <= TranscriptionPrompt.characterCap)
    #expect(prompt.hasSuffix("word\n\n\(Self.base)"))
  }
}

/// What the prompt is *not* allowed to carry. Every signal below is captured at
/// press time and kept on the machine: the focus fields drive the paste path
/// (the leading separator, the injector's window identity) and the developer-mode
/// log, and the key terms ride their own request field (`KeytermsBoost`) rather
/// than this one. `build` is the only door to the wire, so this suite is what
/// stands between a captured context and AssemblyAI's servers.
@Suite("TranscriptionPrompt scope")
struct TranscriptionPromptScopeTests {
  /// The richest context the capture path can produce — every signal populated.
  private let context = TranscriptionContext(
    appName: "Slack", windowTitle: "#eng-backend", fieldLabel: "Message",
    priorText: "thanks for", selectedText: "the draft", keyTerms: ["Blurt"])

  @Test(
    "no captured signal but the prior chunk reaches the prompt",
    arguments: ["Slack", "#eng-backend", "Message", "the draft", "Blurt"])
  func signalStaysLocal(_ signal: String) throws {
    let prompt = try #require(TranscriptionPrompt.build(context: context))
    #expect(!prompt.contains(signal))
  }

  @Test("the built prompt is exactly the prior chunk and the fixed instruction")
  func promptIsPriorChunkAndInstruction() {
    // Pinned whole, not just signal by signal: a new field appended to the prompt
    // would pass every containment check above and fail here.
    #expect(
      TranscriptionPrompt.build(context: context)
        == "Previous transcript:\nthanks for\n\n\(TranscriptionPrompt.baseInstruction)")
  }
}
