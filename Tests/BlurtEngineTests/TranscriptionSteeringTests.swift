import Testing

@testable import BlurtEngine

@Suite("TranscriptionSteering")
struct TranscriptionSteeringTests {
  /// One `build(context:)` → steering-fields expectation. Parameterizing these
  /// (rather than a `@Test` apiece) keeps the whole context→wire contract in one
  /// readable table and gives per-case failure output.
  ///
  /// Each recognized signal has exactly one home, and the table pins both
  /// directions — what renders and what must never leak into the wrong field:
  /// prior-cursor text → `conversation_context`, key terms → `keyterms_prompt`.
  /// Every other focus signal renders nowhere. That includes anything naming the
  /// destination app: the table keeps a case per app family that once earned a
  /// formatting clause, each pinned to `.empty`, so reintroducing app-kind
  /// steering fails here.
  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    let context: TranscriptionContext?
    let expected: TranscriptionSteering.Fields
    var testDescription: String { name }
  }

  static let cases: [Case] = [
    Case(name: "nil context → nothing to steer with", context: nil, expected: .empty),
    Case(
      name: "empty context → nothing to steer with",
      context: TranscriptionContext(appName: nil, priorText: nil), expected: .empty),
    Case(
      name: "whitespace-only context → nothing to steer with",
      context: TranscriptionContext(appName: "  ", priorText: "\n"), expected: .empty),
    Case(
      name: "app name and field label render nowhere",
      context: TranscriptionContext(
        appName: "Mail", windowTitle: "Re: Q3 pricing", fieldLabel: "Body",
        priorText: nil, selectedText: "the old plan"),
      expected: .empty),
    Case(
      name: "prior-cursor text becomes the single conversation-context turn",
      context: TranscriptionContext(appName: "Mail", priorText: "Hi Sam, thanks for"),
      expected: TranscriptionSteering.Fields(
        conversationContext: ["Hi Sam, thanks for"], keyterms: [])),
    Case(
      name: "prior text is trimmed of surrounding whitespace",
      context: TranscriptionContext(appName: nil, priorText: "  Hi Sam,\n "),
      expected: TranscriptionSteering.Fields(conversationContext: ["Hi Sam,"], keyterms: [])),
    Case(
      name: "key terms become keyterms_prompt, not a prompt clause",
      context: TranscriptionContext(appName: nil, priorText: nil, keyTerms: ["AssemblyAI", "Kubernetes"]),
      expected: TranscriptionSteering.Fields(
        conversationContext: [], keyterms: ["AssemblyAI", "Kubernetes"])),
    Case(
      name: "a terminal steers nothing",
      context: TranscriptionContext(appName: "Terminal", windowTitle: "zsh — 80×24", priorText: nil),
      expected: .empty),
    Case(
      name: "a code editor steers nothing, not even the open file's language",
      context: TranscriptionContext(appName: "Code", windowTitle: "main.py — blurt", priorText: nil),
      expected: .empty),
    Case(
      name: "Slack steers nothing",
      context: TranscriptionContext(appName: "Slack", fieldLabel: "Message", priorText: nil),
      expected: .empty),
    Case(
      name: "Obsidian steers nothing",
      context: TranscriptionContext(
        appName: "Obsidian", windowTitle: "Grocery list - Cowork - Obsidian 1.12.7",
        fieldLabel: "text entry area", priorText: nil),
      expected: .empty),
    Case(
      name: "both fields populate independently, and the app still renders nowhere",
      context: TranscriptionContext(
        appName: "Terminal", windowTitle: "zsh — 80×24",
        priorText: "$ git status", selectedText: "modified: README.md", keyTerms: ["Blurt"]),
      expected: TranscriptionSteering.Fields(
        conversationContext: ["$ git status"], keyterms: ["Blurt"])),
  ]

  @Test("build maps focus context to the dictation steering fields", arguments: cases)
  func build(_ c: Case) {
    #expect(TranscriptionSteering.build(context: c.context) == c.expected)
  }

  // MARK: - Selected text never becomes context

  @Test("selected text stays out of conversation context — the paste replaces it")
  func selectedTextIsNotContext() {
    // Selected text is about to be *overwritten* by the paste, so priming the
    // model with it would condition the transcription on text that is on its way
    // out. Only the text before the insertion point is real left-context.
    let fields = TranscriptionSteering.build(
      context: TranscriptionContext(
        appName: nil, priorText: "keep this", selectedText: "REPLACED"))
    #expect(fields.conversationContext == ["keep this"])
  }

  // MARK: - Documented caps

  @Test("an oversized key-terms list is fitted to the keyterms cap, keeping whole leading terms")
  func keyTermsFittedToCap() {
    // Key terms are the one unbounded input (a Settings list of any length), and
    // the field's cap is the total across all terms — so a huge list must be cut
    // to whole terms rather than pushing the request over the documented limit.
    let terms = (0..<2000).map { "term\($0)" }
    let fields = TranscriptionSteering.build(
      context: TranscriptionContext(appName: nil, priorText: nil, keyTerms: terms))
    #expect(fields.keyterms.first == "term0")
    #expect(fields.keyterms.count < terms.count)
    #expect(fields.keyterms.reduce(0) { $0 + $1.count } <= TranscriptionSteering.keytermsCharacterCap)
  }

  @Test("a single key term larger than the cap drops the field entirely")
  func keyTermsOmittedWhenNoneFit() {
    let huge = String(repeating: "k", count: TranscriptionSteering.keytermsCharacterCap + 1)
    let fields = TranscriptionSteering.build(
      context: TranscriptionContext(appName: nil, priorText: nil, keyTerms: [huge]))
    #expect(fields.keyterms.isEmpty)
  }

  @Test("over-long prior text is clipped to the cap, keeping the text nearest the cursor")
  func priorTextClippedToCapKeepingTail() {
    // The words immediately before the insertion point are the ones that carry
    // continuity, so a clip must drop the *head* — the opposite of how the key
    // terms list is fitted. (FocusCapture already caps prior text far below this;
    // the guard is here so a hand-built or future-widened context can't exceed
    // the field's documented limit.)
    let long =
      String(repeating: "a", count: 100)
      + String(repeating: "b", count: TranscriptionSteering.conversationContextCharacterCap)
    let fields = TranscriptionSteering.build(
      context: TranscriptionContext(appName: nil, priorText: long))
    let turn = fields.conversationContext.first ?? ""
    #expect(turn.count == TranscriptionSteering.conversationContextCharacterCap)
    #expect(turn.hasSuffix("b"))
    #expect(!turn.contains("a"))
  }
}
