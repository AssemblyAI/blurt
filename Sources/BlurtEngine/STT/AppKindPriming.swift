import Foundation

/// App-kind guidance for the transcription prompt: recognizes what *kind* of
/// app the dictation targets (a terminal, a code editor, Slack, Obsidian) from
/// the frontmost app's bundle identifier and renders one priming sentence for
/// `TranscriptionPrompt` to place after the destination sentence. The sentence
/// tells the model what shape of text the destination expects — shell commands in a
/// terminal, identifiers and symbols in an editor, casual chat in Slack,
/// Markdown in Obsidian — which the app's display name alone doesn't convey.
///
/// For code editors the window title usually names the open file, so the
/// clause names the language inferred from that filename's extension ("You are
/// writing Python …") when one is recognizable, and stays generic otherwise.
///
/// Detection keys on bundle IDs, not display names: names are localized and
/// user-editable, while the bundle ID is the app's stable identity. An
/// unrecognized app contributes no clause — the prompt simply falls back to
/// the existing destination sentence built from the app name. Wording follows
/// the same Universal-3 Pro prompting guidance as the rest of the prompt
/// (positive/authoritative phrasing, no negations). Exercised by
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

  /// The guidance sentence for the app `bundleID` identifies, or `nil` when
  /// the app isn't recognized. `windowTitle` refines the code-editor clause
  /// with the open file's language; the other kinds ignore it.
  static func clause(bundleID: String?, windowTitle: String?) -> String? {
    guard let kind = kind(ofBundleID: bundleID) else { return nil }
    switch kind {
    case .terminal:
      return "You are dictating into a terminal: expect shell commands, program names, flags, and file paths."
    case .codeEditor:
      let subject = windowTitle.flatMap(language(inWindowTitle:)) ?? "code"
      return "You are writing \(subject) in a code editor: expect code identifiers, symbols, and technical terms."
    case .slack:
      return "You are writing a Slack message: casual tone and emoji are expected."
    case .obsidian:
      return "You are writing a Markdown note in Obsidian: Markdown syntax is expected."
    }
  }

  /// The language of the first token in `title` that reads as a filename with
  /// a recognized extension ("● main.py — blurt — Visual Studio Code" →
  /// "Python"), or `nil` when no token does. Editors lead their window titles
  /// with the open file, so first match wins.
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

  /// Filename extension → how the clause names what's being written. Values
  /// complete "You are writing … in a code editor", so most are bare language
  /// names. Lowercased keys; lookups lowercase the extension first.
  private static let languagesByExtension: [String: String] = [
    "c": "C", "h": "C",
    "cc": "C++", "cpp": "C++", "cxx": "C++", "hpp": "C++",
    "cs": "C#",
    "css": "CSS", "scss": "CSS",
    "go": "Go",
    "htm": "HTML", "html": "HTML",
    "java": "Java",
    "cjs": "JavaScript", "js": "JavaScript", "jsx": "JavaScript", "mjs": "JavaScript",
    "json": "JSON",
    "kt": "Kotlin", "kts": "Kotlin",
    "lua": "Lua",
    "m": "Objective-C", "mm": "Objective-C",
    "markdown": "Markdown", "md": "Markdown",
    "php": "PHP",
    "py": "Python", "pyi": "Python",
    "rb": "Ruby",
    "rs": "Rust",
    "bash": "a shell script", "sh": "a shell script", "zsh": "a shell script",
    "sql": "SQL",
    "swift": "Swift",
    "toml": "TOML",
    "ts": "TypeScript", "tsx": "TypeScript",
    "yaml": "YAML", "yml": "YAML",
  ]
}
