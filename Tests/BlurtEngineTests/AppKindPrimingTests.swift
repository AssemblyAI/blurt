import Testing

@testable import BlurtEngine

@Suite("AppKindPriming")
struct AppKindPrimingTests {
  // MARK: - Kind recognition

  /// One bundle-ID → kind expectation, tabled for per-case failure output like
  /// `TranscriptionSteeringTests.Case`.
  struct KindCase: Sendable, CustomTestStringConvertible {
    let bundleID: String?
    let expected: AppKindPriming.Kind?
    var testDescription: String { bundleID ?? "nil" }
  }

  static let kindCases: [KindCase] = [
    KindCase(bundleID: "com.apple.Terminal", expected: .terminal),
    KindCase(bundleID: "com.googlecode.iterm2", expected: .terminal),
    KindCase(bundleID: "com.mitchellh.ghostty", expected: .terminal),
    KindCase(bundleID: "com.microsoft.VSCode", expected: .codeEditor),
    KindCase(bundleID: "com.apple.dt.Xcode", expected: .codeEditor),
    KindCase(bundleID: "com.todesktop.230313mzl4w4u92", expected: .codeEditor),
    // Prefix families: any JetBrains IDE, any Sublime Text major version.
    KindCase(bundleID: "com.jetbrains.pycharm", expected: .codeEditor),
    KindCase(bundleID: "com.sublimetext.4", expected: .codeEditor),
    KindCase(bundleID: "com.tinyspeck.slackmacgap", expected: .slack),
    KindCase(bundleID: "md.obsidian", expected: .obsidian),
    KindCase(bundleID: "com.apple.mail", expected: nil),
    KindCase(bundleID: "", expected: nil),
    KindCase(bundleID: "   ", expected: nil),
    KindCase(bundleID: nil, expected: nil),
  ]

  @Test("bundle IDs map to their app kind", arguments: kindCases)
  func kind(_ c: KindCase) {
    #expect(AppKindPriming.kind(ofBundleID: c.bundleID) == c.expected)
  }

  // MARK: - Language inference from window titles

  /// One window-title → language expectation.
  struct LanguageCase: Sendable, CustomTestStringConvertible {
    let title: String
    let expected: String?
    var testDescription: String { title }
  }

  static let languageCases: [LanguageCase] = [
    LanguageCase(title: "main.py — blurt — Visual Studio Code", expected: "Python code"),
    // VS Code prepends ● to the filename of a dirty buffer.
    LanguageCase(title: "● api.ts — server", expected: "TypeScript code"),
    LanguageCase(title: "blurt — TranscriptionPrompt.swift", expected: "Swift code"),
    LanguageCase(title: "deploy.sh — infra", expected: "a shell script"),
    // Extension matching is case-insensitive.
    LanguageCase(title: "README.MD — notes", expected: "markdown"),
    // First filename wins when several tokens carry extensions.
    LanguageCase(title: "index.js next.config.ts", expected: "JavaScript code"),
    // A dotfile has no base name + extension split.
    LanguageCase(title: ".zshrc — dotfiles", expected: nil),
    // Version numbers and hostnames are not filenames.
    LanguageCase(title: "release v0.1.34 — dictation.assemblyai.com", expected: nil),
    LanguageCase(title: "Untitled-1", expected: nil),
    LanguageCase(title: "", expected: nil),
  ]

  @Test("window titles yield the open file's language", arguments: languageCases)
  func language(_ c: LanguageCase) {
    #expect(AppKindPriming.language(inWindowTitle: c.title) == c.expected)
  }

  // MARK: - Clause rendering

  @Test("a terminal renders the shell-command formatting instruction")
  func terminalClause() {
    #expect(
      AppKindPriming.clause(bundleID: "com.apple.Terminal", windowTitle: nil)
        == "Format the result as a shell command with no trailing period.")
  }

  @Test("a code editor names the open file's language when the title carries one")
  func codeEditorClauseWithLanguage() {
    #expect(
      AppKindPriming.clause(bundleID: "com.microsoft.VSCode", windowTitle: "main.py — blurt")
        == "Format the result as Python code.")
  }

  @Test("a code editor stays generic when the title names no recognizable file")
  func codeEditorClauseGeneric() {
    #expect(
      AppKindPriming.clause(bundleID: "com.apple.dt.Xcode", windowTitle: "Welcome to Xcode")
        == "Format the result as code.")
  }

  @Test("Slack renders the casual-message formatting instruction")
  func slackClause() {
    #expect(
      AppKindPriming.clause(bundleID: "com.tinyspeck.slackmacgap", windowTitle: "#eng-backend")
        == "Format the result as a casual Slack message, using Slack emoji where they fit.")
  }

  @Test("Obsidian renders the markdown formatting instruction")
  func obsidianClause() {
    #expect(
      AppKindPriming.clause(bundleID: "md.obsidian", windowTitle: "Meeting notes")
        == "Format the result as markdown.")
  }

  @Test("every clause reads as a rewrite instruction, not a transcription instruction")
  func clausesAreRewriteInstructions() {
    // These render into `config.llm.instruction`, which is an instruction to an
    // LLM rewriting finished text. The Sync STT docs are explicit that
    // `config.prompt` takes a *description of the audio* instead — so a clause
    // that slipped back into "Transcribe speech into …" phrasing would be aimed
    // at the wrong field, which is how the app-kind priming was silently a no-op
    // before.
    for bundleID in ["com.apple.Terminal", "com.microsoft.VSCode", "com.tinyspeck.slackmacgap", "md.obsidian"] {
      let clause = AppKindPriming.clause(bundleID: bundleID, windowTitle: nil)
      #expect(clause?.hasPrefix("Format the result as ") == true, "\(bundleID)")
      #expect(clause?.contains("Transcribe") == false, "\(bundleID)")
    }
  }

  @Test("an unrecognized app contributes no clause")
  func unrecognizedApp() {
    #expect(AppKindPriming.clause(bundleID: "com.apple.mail", windowTitle: "Re: Q3") == nil)
    #expect(AppKindPriming.clause(bundleID: nil, windowTitle: "main.py") == nil)
  }
}
