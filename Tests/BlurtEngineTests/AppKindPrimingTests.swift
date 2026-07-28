import Testing

@testable import BlurtEngine

@Suite("AppKindPriming")
struct AppKindPrimingTests {
  // MARK: - Kind recognition

  /// One bundle-ID → kind expectation, tabled for per-case failure output like
  /// `TranscriptionPromptTests.Case`.
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
    LanguageCase(title: "main.py — blurt — Visual Studio Code", expected: "Python"),
    // VS Code prepends ● to the filename of a dirty buffer.
    LanguageCase(title: "● api.ts — server", expected: "TypeScript"),
    LanguageCase(title: "blurt — TranscriptionPrompt.swift", expected: "Swift"),
    LanguageCase(title: "deploy.sh — infra", expected: "a shell script"),
    // Extension matching is case-insensitive.
    LanguageCase(title: "README.MD — notes", expected: "Markdown"),
    // First filename wins when several tokens carry extensions.
    LanguageCase(title: "index.js next.config.ts", expected: "JavaScript"),
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

  @Test("a terminal renders the command-line clause")
  func terminalClause() {
    #expect(
      AppKindPriming.clause(bundleID: "com.apple.Terminal", windowTitle: nil)
        == "You are dictating into a terminal: expect shell commands, program names, flags, and file paths.")
  }

  @Test("a code editor names the open file's language when the title carries one")
  func codeEditorClauseWithLanguage() {
    #expect(
      AppKindPriming.clause(bundleID: "com.microsoft.VSCode", windowTitle: "main.py — blurt")
        == "You are writing Python in a code editor: expect code identifiers, symbols, and technical terms.")
  }

  @Test("a code editor stays generic when the title names no recognizable file")
  func codeEditorClauseGeneric() {
    #expect(
      AppKindPriming.clause(bundleID: "com.apple.dt.Xcode", windowTitle: "Welcome to Xcode")
        == "You are writing code in a code editor: expect code identifiers, symbols, and technical terms.")
  }

  @Test("Slack renders the casual-chat clause")
  func slackClause() {
    #expect(
      AppKindPriming.clause(bundleID: "com.tinyspeck.slackmacgap", windowTitle: "#eng-backend")
        == "You are writing a Slack message: casual tone and emoji are expected.")
  }

  @Test("Obsidian renders the Markdown clause")
  func obsidianClause() {
    #expect(
      AppKindPriming.clause(bundleID: "md.obsidian", windowTitle: "Meeting notes")
        == "You are writing a Markdown note in Obsidian: Markdown syntax is expected.")
  }

  @Test("an unrecognized app contributes no clause")
  func unrecognizedApp() {
    #expect(AppKindPriming.clause(bundleID: "com.apple.mail", windowTitle: "Re: Q3") == nil)
    #expect(AppKindPriming.clause(bundleID: nil, windowTitle: "main.py") == nil)
  }
}
