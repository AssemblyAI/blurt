import Foundation

/// The app-kind formatting instruction: recognizes what *kind* of app the
/// dictation targets (a terminal, a code editor, Slack, Obsidian) from the
/// frontmost app's bundle identifier and renders the one sentence
/// `TranscriptionSteering` sends as `config.llm.instruction` — "Format the
/// result as a shell command with no trailing period." / "… as Swift code." /
/// "… as a casual Slack message, using Slack emoji where they fit." / "… as
/// markdown." — telling the rewrite what shape of text the destination expects,
/// which the app's display name alone doesn't convey.
///
/// For code editors the window title usually names the open file, so the
/// clause names the language inferred from that filename's extension
/// ("Format the result as Python code.") when one is recognizable, and stays
/// generic ("… as code.") otherwise.
///
/// These are instructions to the **LLM that rewrites the finished transcript**,
/// not to the STT model. Reshaping output is not something `config.prompt` acts
/// on — that field takes a description of the audio — so a clause phrased as
/// "Transcribe speech into markdown." was a no-op wherever it landed. Keep the
/// imperative "Format the result as …" shape.
///
/// Detection keys on bundle IDs, not display names: names are localized and
/// user-editable, while the bundle ID is the app's stable identity. An
/// unrecognized app contributes no clause — the request's `llm` block is then
/// empty and the service's own default cleanup instruction applies. Exercised by
/// `Tests/BlurtEngineTests/AppKindPrimingTests.swift`.
enum AppKindPriming {
  /// The recognized destination families. Each renders one guidance sentence;
  /// anything else contributes no clause.
  enum Kind: Sendable, Equatable {
    case terminal
    case codeEditor
    case slack
    case obsidian
  }

  /// Exact bundle-ID → kind matches for the recognized apps.
  private static let kindsByBundleID: [String: Kind] = [
    // Terminals.
    "com.apple.Terminal": .terminal,
    "com.googlecode.iterm2": .terminal,
    "dev.warp.Warp-Stable": .terminal,
    "dev.warp.Warp-Preview": .terminal,
    "com.mitchellh.ghostty": .terminal,
    "net.kovidgoyal.kitty": .terminal,
    "org.alacritty": .terminal,
    "com.github.wez.wezterm": .terminal,
    "co.zeit.hyper": .terminal,
    // Code editors. Cursor ships under an opaque ToDesktop build id.
    "com.microsoft.VSCode": .codeEditor,
    "com.microsoft.VSCodeInsiders": .codeEditor,
    "com.vscodium": .codeEditor,
    "com.todesktop.230313mzl4w4u92": .codeEditor,
    "com.exafunction.windsurf": .codeEditor,
    "com.apple.dt.Xcode": .codeEditor,
    "dev.zed.Zed": .codeEditor,
    "dev.zed.Zed-Preview": .codeEditor,
    "com.panic.Nova": .codeEditor,
    "com.macromates.TextMate": .codeEditor,
    // Chat and notes.
    "com.tinyspeck.slackmacgap": .slack,
    "md.obsidian": .obsidian,
  ]

  /// Prefix matches for app families that ship many bundle IDs under one
  /// vendor prefix (every JetBrains IDE, Sublime Text's versioned IDs).
  private static let kindsByBundleIDPrefix: [(prefix: String, kind: Kind)] = [
    ("com.jetbrains.", .codeEditor),
    ("com.sublimetext.", .codeEditor),
  ]

  /// The kind `bundleID` identifies, or `nil` for an unrecognized (or absent)
  /// bundle ID.
  static func kind(ofBundleID bundleID: String?) -> Kind? {
    guard let bundleID = bundleID.trimmedNonEmpty() else { return nil }
    if let kind = kindsByBundleID[bundleID] { return kind }
    return kindsByBundleIDPrefix.first { bundleID.hasPrefix($0.prefix) }?.kind
  }

  /// The formatting instruction for the app `bundleID` identifies, or `nil` when
  /// the app isn't recognized. `windowTitle` refines the code-editor clause
  /// with the open file's language; the other kinds ignore it.
  static func clause(bundleID: String?, windowTitle: String?) -> String? {
    guard let kind = kind(ofBundleID: bundleID) else { return nil }
    switch kind {
    case .terminal:
      // "Trailing period", not "terminal punctuation": in a clause about
      // terminals the latter reads as the app, not the end of a sentence.
      return "Format the result as a shell command with no trailing period."
    case .codeEditor:
      let subject = windowTitle.flatMap(language(inWindowTitle:)) ?? "code"
      return "Format the result as \(subject)."
    case .slack:
      return "Format the result as a casual Slack message, using Slack emoji where they fit."
    case .obsidian:
      return "Format the result as markdown."
    }
  }

  /// What the open file says speech becomes, from the first token in `title`
  /// that reads as a filename with a recognized extension
  /// ("● main.py — blurt — Visual Studio Code" → "Python code"), or `nil` when
  /// no token does. Editors lead their window titles with the open file, so
  /// first match wins.
  static func language(inWindowTitle title: String) -> String? {
    for token in title.split(whereSeparator: \.isWhitespace) {
      let name = token.trimmingCharacters(in: Self.filenameTrim)
      // A leading-dot name (".zshrc") is a dotfile, not a base name + extension.
      guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { continue }
      if let language = languagesByExtension[name[name.index(after: dot)...].lowercased()] {
        return language
      }
    }
    return nil
  }

  /// Decoration editors wrap around the filename in a window title — dirty
  /// markers, quotes, brackets, dash separators.
  private static let filenameTrim = CharacterSet(charactersIn: "\"'`•●◆*()[]{}<>,;:—–-")

  /// Filename extension → what the clause says the result should be. Values
  /// complete "Format the result as …", so languages carry a trailing "code"
  /// while markup/data formats stand alone. Lowercased keys; lookups lowercase
  /// the extension first.
  private static let languagesByExtension: [String: String] = [
    "c": "C code", "h": "C code",
    "cc": "C++ code", "cpp": "C++ code", "cxx": "C++ code", "hpp": "C++ code",
    "cs": "C# code",
    "css": "CSS", "scss": "CSS",
    "go": "Go code",
    "htm": "HTML", "html": "HTML",
    "java": "Java code",
    "cjs": "JavaScript code", "js": "JavaScript code", "jsx": "JavaScript code", "mjs": "JavaScript code",
    "json": "JSON",
    "kt": "Kotlin code", "kts": "Kotlin code",
    "lua": "Lua code",
    "m": "Objective-C code", "mm": "Objective-C code",
    "markdown": "markdown", "md": "markdown",
    "php": "PHP code",
    "py": "Python code", "pyi": "Python code",
    "rb": "Ruby code",
    "rs": "Rust code",
    "bash": "a shell script", "sh": "a shell script", "zsh": "a shell script",
    "sql": "SQL",
    "swift": "Swift code",
    "toml": "TOML",
    "ts": "TypeScript code", "tsx": "TypeScript code",
    "yaml": "YAML", "yml": "YAML",
  ]
}
