import Testing

@testable import BlurtEngine

@Suite("TranscriptionPrompt")
struct TranscriptionPromptTests {
  /// One `build(context:)` → prompt expectation. Parameterizing these (rather
  /// than a `@Test` apiece) keeps the whole context→prompt contract in one
  /// readable table and gives per-case failure output.
  ///
  /// The prompt is contextual priming only — no standing instruction opens it.
  /// The annotation-suppression clause ("Transcribe without speaker labels, …")
  /// is part of the dictation service's own default prompt, so a case's
  /// expectation is exactly its context rendered, nothing more.
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
      expected: "Dictated into Slack."),
    Case(
      name: "prior only → Previous transcript framing",
      context: TranscriptionContext(appName: nil, priorText: "and then the build finished"),
      expected: "Previous transcript:\nand then the build finished"),
    Case(
      name: "app + window → topic hint leads, destination trails",
      context: TranscriptionContext(appName: "Mail", windowTitle: "Re: Q3 pricing", priorText: nil),
      expected: "This is about \"Re: Q3 pricing\". Dictated into Mail."),
    Case(
      name: "window only → bare topic hint",
      context: TranscriptionContext(appName: nil, windowTitle: "Untitled.txt", priorText: nil),
      expected: "This is about \"Untitled.txt\"."),
    Case(
      name: "field only → destination sentence",
      context: TranscriptionContext(appName: nil, fieldLabel: "Search", priorText: nil),
      expected: "Dictated in the \"Search\" field."),
    Case(
      name: "app + field without window → destination names both",
      context: TranscriptionContext(appName: "Slack", fieldLabel: "Message", priorText: nil),
      expected: "Dictated into Slack, in the \"Message\" field."),
    Case(
      name: "all four signals combine",
      context: TranscriptionContext(
        appName: "Slack", windowTitle: "#eng-backend", fieldLabel: "Message", priorText: "thanks for"),
      expected:
        "Previous transcript:\nthanks for\n\nThis is about \"#eng-backend\". Dictated into Slack, in the \"Message\" field."
    ),
    Case(
      name: "prior + app combine",
      context: TranscriptionContext(appName: "Mail", priorText: "Dear Sam,"),
      expected: "Previous transcript:\nDear Sam,\n\nDictated into Mail."),
    Case(
      name: "prior + app are trimmed",
      context: TranscriptionContext(appName: "  Notes  ", priorText: "  hello  "),
      expected: "Previous transcript:\nhello\n\nDictated into Notes."),
    Case(
      name: "selected only → Selected text framing",
      context: TranscriptionContext(appName: nil, priorText: nil, selectedText: "the quarterly numbers"),
      expected: "Selected text:\nthe quarterly numbers"),
    Case(
      name: "selected follows prior as its own block",
      context: TranscriptionContext(appName: nil, priorText: "as we discussed,", selectedText: "the old plan"),
      expected: "Previous transcript:\nas we discussed,\n\nSelected text:\nthe old plan"),
    Case(
      name: "selected + location + prior combine",
      context: TranscriptionContext(
        appName: "Mail", windowTitle: "Re: Q3 pricing", fieldLabel: "Body",
        priorText: "Hi Sam,", selectedText: "let's push the date"),
      expected:
        "Previous transcript:\nHi Sam,\n\nSelected text:\nlet's push the date\n\nThis is about \"Re: Q3 pricing\". Dictated into Mail, in the \"Body\" field."
    ),
    Case(
      name: "blank selected adds no block",
      context: TranscriptionContext(appName: "Notes", priorText: nil, selectedText: "   \n"),
      expected: "Dictated into Notes."),
    Case(
      name: "selected sits between prior and keyword boost",
      context: TranscriptionContext(
        appName: "Slack", priorText: "thanks for", selectedText: "the draft", keyTerms: ["Blurt"]),
      expected:
        "Previous transcript:\nthanks for\n\nSelected text:\nthe draft\n\nDictated into Slack. Keywords: Blurt."
    ),
    Case(
      name: "recognized bundle ID → app-kind guidance after the destination",
      context: TranscriptionContext(
        appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", fieldLabel: "Message", priorText: nil),
      expected:
        "Dictated into Slack, in the \"Message\" field. You are writing a Slack message: casual tone and emoji are expected."
    ),
    Case(
      name: "bundle ID alone → guidance still built",
      context: TranscriptionContext(appName: nil, bundleID: "com.apple.Terminal", priorText: nil),
      expected:
        "You are dictating into a terminal: expect shell commands, program names, flags, and file paths."
    ),
    Case(
      name: "code-editor guidance names the window title's language",
      context: TranscriptionContext(
        appName: "Code", bundleID: "com.microsoft.VSCode", windowTitle: "main.py — blurt", priorText: nil),
      expected:
        "This is about \"main.py — blurt\". Dictated into Code. You are writing Python in a code editor: expect code identifiers, symbols, and technical terms."
    ),
    Case(
      name: "unrecognized bundle ID adds no guidance",
      context: TranscriptionContext(appName: "Mail", bundleID: "com.apple.mail", priorText: nil),
      expected: "Dictated into Mail."),
    Case(
      name: "unrecognized bundle ID with no other signal → no prompt",
      context: TranscriptionContext(appName: nil, bundleID: "com.example.mystery", priorText: nil),
      expected: nil),
    Case(
      name: "key terms only → bare keyword boost",
      context: TranscriptionContext(appName: nil, priorText: nil, keyTerms: ["AssemblyAI", "Kubernetes"]),
      expected: "Keywords: AssemblyAI, Kubernetes."),
    Case(
      name: "key terms trail the focus context inline",
      context: TranscriptionContext(appName: "Slack", priorText: nil, keyTerms: ["Blurt"]),
      expected: "Dictated into Slack. Keywords: Blurt."),
    Case(
      name: "empty key terms add no clause",
      context: TranscriptionContext(appName: "Notes", priorText: nil, keyTerms: []),
      expected: "Dictated into Notes."),
  ]

  @Test("build maps focus context to the transcription prompt", arguments: cases)
  func build(_ c: Case) {
    #expect(TranscriptionPrompt.build(context: c.context) == c.expected)
  }

  @Test("built prompt fits within the API's 4096-character cap for capped prior text")
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
    #expect(prompt == "Dictated into Xcode.")
  }

  @Test("a key-terms-only prompt whose first term doesn't fit yields no prompt at all")
  func keyTermsOnlyNoneFit() {
    // With no other context and no term fitting the cap, nothing renders — and
    // an empty prompt must collapse to nil so the server default applies.
    let huge = String(repeating: "k", count: TranscriptionPrompt.characterCap)
    let prompt = TranscriptionPrompt.build(
      context: TranscriptionContext(appName: nil, priorText: nil, keyTerms: [huge]))
    #expect(prompt == nil)
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
