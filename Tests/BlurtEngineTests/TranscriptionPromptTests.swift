import Testing

@testable import BlurtEngine

@Suite("TranscriptionPrompt")
struct TranscriptionPromptTests {
  /// One `build(context:)` → prompt expectation. Parameterizing these (rather
  /// than a `@Test` apiece) keeps the whole context→prompt contract in one
  /// readable table and gives per-case failure output.
  ///
  /// The prompt is the app-kind instruction plus trailing keyword boosting —
  /// nothing else. The other focus signals (app name, window title, field
  /// label, prior text, selected text) are captured for the dictation log and
  /// the injector, and must never surface in the prompt; the cases below pin
  /// both directions.
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
      name: "focus signals alone render nothing — log-only, not prompt",
      context: TranscriptionContext(
        appName: "Mail", windowTitle: "Re: Q3 pricing", fieldLabel: "Body",
        priorText: "Hi Sam,", selectedText: "the old plan"),
      expected: nil),
    Case(
      name: "unrecognized bundle ID renders nothing",
      context: TranscriptionContext(appName: "Mail", bundleID: "com.apple.mail", priorText: nil),
      expected: nil),
    Case(
      name: "terminal → shell-commands instruction",
      context: TranscriptionContext(appName: "Terminal", bundleID: "com.apple.Terminal", priorText: nil),
      expected: "Transcribe speech into shell commands."),
    Case(
      name: "code editor names the window title's language",
      context: TranscriptionContext(
        appName: "Code", bundleID: "com.microsoft.VSCode", windowTitle: "main.py — blurt", priorText: nil),
      expected: "Transcribe speech into Python code."),
    Case(
      name: "code editor with no recognizable filename stays generic",
      context: TranscriptionContext(
        appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "Welcome to Xcode", priorText: nil),
      expected: "Transcribe speech into code."),
    Case(
      name: "Slack → casual-message instruction",
      context: TranscriptionContext(
        appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", fieldLabel: "Message", priorText: nil),
      expected: "Transcribe speech into a casual Slack message with emoji."),
    Case(
      name: "Obsidian → markdown instruction, window/field stay out",
      context: TranscriptionContext(
        appName: "Obsidian", bundleID: "md.obsidian",
        windowTitle: "Grocery list - Cowork - Obsidian 1.12.7", fieldLabel: "text entry area",
        priorText: nil),
      expected: "Transcribe speech into markdown."),
    Case(
      name: "prior/selected text never precede the instruction",
      context: TranscriptionContext(
        appName: "Terminal", bundleID: "com.apple.Terminal", windowTitle: "zsh — 80×24",
        priorText: "$ git status", selectedText: "modified: README.md"),
      expected: "Transcribe speech into shell commands."),
    Case(
      name: "key terms only → bare keyword boost",
      context: TranscriptionContext(appName: nil, priorText: nil, keyTerms: ["AssemblyAI", "Kubernetes"]),
      expected: "Keywords: AssemblyAI, Kubernetes."),
    Case(
      name: "key terms trail the instruction inline",
      context: TranscriptionContext(
        appName: "Terminal", bundleID: "com.apple.Terminal", priorText: nil, keyTerms: ["Blurt"]),
      expected: "Transcribe speech into shell commands. Keywords: Blurt."),
    Case(
      name: "empty key terms add no clause",
      context: TranscriptionContext(appName: nil, bundleID: "md.obsidian", priorText: nil, keyTerms: []),
      expected: "Transcribe speech into markdown."),
  ]

  @Test("build maps focus context to the transcription prompt", arguments: cases)
  func build(_ c: Case) {
    #expect(TranscriptionPrompt.build(context: c.context) == c.expected)
  }

  @Test("the keyword clause is omitted entirely when not even the first term fits")
  func keyTermsOmittedWhenNoneFit() {
    // A single term longer than the whole cap leaves no budget for even one
    // keyword: the clause (and its "Keywords:" scaffolding) must be dropped
    // whole, not emitted empty or dangling.
    let huge = String(repeating: "k", count: TranscriptionPrompt.characterCap)
    let prompt = TranscriptionPrompt.build(
      context: TranscriptionContext(
        appName: "Terminal", bundleID: "com.apple.Terminal", priorText: nil, keyTerms: [huge]))
    #expect(prompt == "Transcribe speech into shell commands.")
  }

  @Test("a key-terms-only prompt whose first term doesn't fit yields no prompt at all")
  func keyTermsOnlyNoneFit() {
    // With no instruction and no term fitting the cap, nothing renders — and
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
      context: TranscriptionContext(
        appName: "Terminal", bundleID: "com.apple.Terminal", priorText: nil, keyTerms: terms))
    let built = try #require(prompt)
    #expect(built.count <= TranscriptionPrompt.characterCap)
    #expect(built.contains(" Keywords: term0, term1"))
    #expect(built.hasSuffix("."))
  }
}
