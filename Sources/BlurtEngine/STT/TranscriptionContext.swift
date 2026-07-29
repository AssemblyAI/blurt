/// Per-utterance snapshot of where the dictation is going, gathered at
/// dictation start from the focused app and field. `TranscriptionPrompt.build`
/// renders only the parts of it the request prompt uses — the bundle ID (via
/// the `AppKindPriming` app-kind instruction), the window title (the language
/// refinement of that instruction), and the key terms. The prior text and
/// window title also steer the injector's paste separator; nothing else is
/// consumed, and none of the raw context is sent or logged.
///
/// Every focus field is optional and best-effort: whatever couldn't be read is
/// `nil`, and an entirely empty context yields no prompt (the server applies
/// its own default).
public struct TranscriptionContext: Sendable, Equatable {
  /// The frontmost application's display name (e.g. "Slack", "Xcode"). Not
  /// rendered into the prompt.
  public let appName: String?

  /// The frontmost application's bundle identifier (e.g.
  /// "com.tinyspeck.slackmacgap"). Never rendered verbatim: it keys the
  /// app-*kind* recognition (`AppKindPriming`) that selects the prompt's
  /// transcription instruction — terminal, code editor, Slack, Obsidian.
  /// Preferred over `appName` for recognition because display names are
  /// localized and user-editable while the bundle ID is stable.
  public let bundleID: String?

  /// The focused window's title (e.g. "main.py — blurt", a document name, a
  /// Slack channel). In a code editor it usually names the open file, which is
  /// how the app-kind instruction learns the language ("… into Swift code.");
  /// it also anchors the injector's same-window separator fallback.
  public let windowTitle: String?

  /// A short label for the focused field (placeholder/title/role, e.g. "To",
  /// "Subject", "Search", "Message"). Not rendered into the prompt.
  public let fieldLabel: String?

  /// Text immediately preceding the insertion point in the focused field. Not
  /// rendered into the prompt; it drives the injector's leading-separator
  /// decision.
  public let priorText: String?

  /// The text currently selected in the focused field, when any (the paste
  /// will replace it). Not rendered into the prompt.
  public let selectedText: String?

  /// User-configured domain vocabulary (names, jargon, product names) carried as
  /// spelling priming so the model favors these spellings. Unlike the other
  /// fields this isn't per-utterance focus state — it's the same list every time,
  /// sourced from `KeyTermsStore`.
  public let keyTerms: [String]

  public init(
    appName: String?,
    bundleID: String? = nil,
    windowTitle: String? = nil,
    fieldLabel: String? = nil,
    priorText: String?,
    selectedText: String? = nil,
    keyTerms: [String] = []
  ) {
    self.appName = appName
    self.bundleID = bundleID
    self.windowTitle = windowTitle
    self.fieldLabel = fieldLabel
    self.priorText = priorText
    self.selectedText = selectedText
    self.keyTerms = keyTerms
  }

  /// True when no focus field carries usable (non-whitespace) content and there
  /// are no key terms.
  public var isEmpty: Bool {
    keyTerms.isEmpty
      && [appName, bundleID, windowTitle, fieldLabel, priorText, selectedText].allSatisfy {
        $0.trimmedNonEmpty() == nil
      }
  }
}
