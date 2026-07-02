import Testing

@testable import BlurtEngine

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
      name: "whitespace-only context → no prompt",
      context: TranscriptionContext(appName: "  ", priorText: "\n"), expected: nil),
    Case(
      name: "app only → destination sentence",
      context: TranscriptionContext(appName: "Slack", priorText: nil),
      expected: "Dictated into Slack. \(base)"),
    Case(
      name: "prior only → Previous transcript framing",
      context: TranscriptionContext(appName: nil, priorText: "and then the build finished"),
      expected: "Previous transcript:\nand then the build finished\n\n\(base)"),
    Case(
      name: "app + window → topic hint leads, destination trails",
      context: TranscriptionContext(appName: "Mail", windowTitle: "Re: Q3 pricing", priorText: nil),
      expected: "This is about \"Re: Q3 pricing\". Dictated into Mail. \(base)"),
    Case(
      name: "window only → bare topic hint",
      context: TranscriptionContext(appName: nil, windowTitle: "Untitled.txt", priorText: nil),
      expected: "This is about \"Untitled.txt\". \(base)"),
    Case(
      name: "field only → destination sentence",
      context: TranscriptionContext(appName: nil, fieldLabel: "Search", priorText: nil),
      expected: "Dictated in the \"Search\" field. \(base)"),
    Case(
      name: "app + field without window → destination names both",
      context: TranscriptionContext(appName: "Slack", fieldLabel: "Message", priorText: nil),
      expected: "Dictated into Slack, in the \"Message\" field. \(base)"),
    Case(
      name: "all four signals combine",
      context: TranscriptionContext(
        appName: "Slack", windowTitle: "#eng-backend", fieldLabel: "Message", priorText: "thanks for"),
      expected:
        "Previous transcript:\nthanks for\n\nThis is about \"#eng-backend\". Dictated into Slack, in the \"Message\" field. \(base)"
    ),
    Case(
      name: "prior + app combine",
      context: TranscriptionContext(appName: "Mail", priorText: "Dear Sam,"),
      expected: "Previous transcript:\nDear Sam,\n\nDictated into Mail. \(base)"),
    Case(
      name: "prior + app are trimmed",
      context: TranscriptionContext(appName: "  Notes  ", priorText: "  hello  "),
      expected: "Previous transcript:\nhello\n\nDictated into Notes. \(base)"),
    Case(
      name: "selected only → Selected text framing",
      context: TranscriptionContext(appName: nil, priorText: nil, selectedText: "the quarterly numbers"),
      expected: "Selected text:\nthe quarterly numbers\n\n\(base)"),
    Case(
      name: "selected follows prior as its own block",
      context: TranscriptionContext(appName: nil, priorText: "as we discussed,", selectedText: "the old plan"),
      expected: "Previous transcript:\nas we discussed,\n\nSelected text:\nthe old plan\n\n\(base)"),
    Case(
      name: "selected + location + prior combine",
      context: TranscriptionContext(
        appName: "Mail", windowTitle: "Re: Q3 pricing", fieldLabel: "Body",
        priorText: "Hi Sam,", selectedText: "let's push the date"),
      expected:
        "Previous transcript:\nHi Sam,\n\nSelected text:\nlet's push the date\n\nThis is about \"Re: Q3 pricing\". Dictated into Mail, in the \"Body\" field. \(base)"
    ),
    Case(
      name: "blank selected adds no block",
      context: TranscriptionContext(appName: "Notes", priorText: nil, selectedText: "   \n"),
      expected: "Dictated into Notes. \(base)"),
    Case(
      name: "selected sits between prior and keyword boost",
      context: TranscriptionContext(
        appName: "Slack", priorText: "thanks for", selectedText: "the draft", keyTerms: ["Blurt"]),
      expected:
        "Previous transcript:\nthanks for\n\nSelected text:\nthe draft\n\nDictated into Slack. \(base) Keywords: Blurt."
    ),
    Case(
      name: "key terms only → inline keyword boost",
      context: TranscriptionContext(appName: nil, priorText: nil, keyTerms: ["AssemblyAI", "Kubernetes"]),
      expected: "\(base) Keywords: AssemblyAI, Kubernetes."),
    Case(
      name: "key terms trail base alongside focus context",
      context: TranscriptionContext(appName: "Slack", priorText: nil, keyTerms: ["Blurt"]),
      expected: "Dictated into Slack. \(base) Keywords: Blurt."),
    Case(
      name: "empty key terms add no clause",
      context: TranscriptionContext(appName: "Notes", priorText: nil, keyTerms: []),
      expected: "Dictated into Notes. \(base)"),
  ]

  @Test("build maps focus context to the Sync prompt", arguments: cases)
  func build(_ c: Case) {
    #expect(TranscriptionPrompt.build(context: c.context) == c.expected)
  }

  @Test("built prompt fits within the Sync API 4096-character cap for capped prior text")
  func withinCap() {
    let longPrior = String(repeating: "word ", count: 200)
    let prompt = TranscriptionPrompt.build(
      context: TranscriptionContext(appName: "Xcode", priorText: longPrior))
    #expect((prompt?.count ?? 0) <= TranscriptionPrompt.characterCap)
  }

  @Test("the keyword clause is omitted entirely when not even the first term fits")
  func keyTermsOmittedWhenNoneFit() {
    // A single term longer than the whole cap leaves no budget for even one
    // keyword: the clause (and its "Keywords:" scaffolding) must be dropped
    // whole, not emitted empty or dangling.
    let huge = String(repeating: "k", count: TranscriptionPrompt.characterCap)
    let prompt = TranscriptionPrompt.build(
      context: TranscriptionContext(appName: "Xcode", priorText: nil, keyTerms: [huge]))
    #expect(prompt == "Dictated into Xcode. \(Self.base)")
  }

  @Test("an oversized key-terms list is fitted to the cap, keeping whole leading terms")
  func keyTermsFittedToCap() throws {
    // Key terms are the one input with no upstream length cap; a huge Settings
    // list must not push the prompt over the API cap (which fails the request).
    let terms = (0..<2000).map { "term\($0)" }
    let prompt = TranscriptionPrompt.build(
      context: TranscriptionContext(appName: "Xcode", priorText: nil, keyTerms: terms))
    let built = try #require(prompt)
    #expect(built.count <= TranscriptionPrompt.characterCap)
    #expect(built.contains(" Keywords: term0, term1"))
    #expect(built.hasSuffix("."))
  }
}
