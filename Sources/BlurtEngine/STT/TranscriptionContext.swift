/// Per-utterance context the Sync STT model is trained to use as *contextual*
/// priming — it improves recognition accuracy (vocabulary, continuity,
/// capitalization) without changing the output format. Gathered at dictation
/// start from the focused app and the text preceding the cursor, then rendered
/// into the request `prompt` by `TranscriptionPrompt.build`.
///
/// Both fields are optional: whichever is available is used, and an entirely
/// empty context yields no prompt (the server applies its own default).
public struct TranscriptionContext: Sendable, Equatable {
  /// The frontmost application's display name (e.g. "Slack", "Xcode"), passed
  /// as a domain/topic hint so the model expects that app's vocabulary.
  public let appName: String?

  /// The focused window's title (e.g. "Re: Q3 pricing — Gmail", a document
  /// name, a Slack channel). The densest topic hint available — usually packed
  /// with the proper nouns and domain vocabulary the model would otherwise guess.
  public let windowTitle: String?

  /// A short label for the focused field (placeholder/title/role, e.g. "To",
  /// "Subject", "Search", "Message"), passed so the model knows what *kind* of
  /// text is expected — an email address, a search query, and prose should be
  /// transcribed differently.
  public let fieldLabel: String?

  /// Text immediately preceding the insertion point in the focused field,
  /// passed as "prior chunk context" so the transcript continues naturally.
  public let priorText: String?

  /// The text currently selected in the focused field, when any. Dictating with
  /// a selection replaces it (the paste overwrites the highlighted range), so
  /// this is passed as priming for what the utterance is about — the vocabulary
  /// and topic of the text being rewritten.
  public let selectedText: String?

  /// User-configured domain vocabulary (names, jargon, product names) carried as
  /// spelling priming so the model favors these spellings. Unlike the other
  /// fields this isn't per-utterance focus state — it's the same list every time,
  /// sourced from `KeyTermsStore`.
  public let keyTerms: [String]

  public init(
    appName: String?,
    windowTitle: String? = nil,
    fieldLabel: String? = nil,
    priorText: String?,
    selectedText: String? = nil,
    keyTerms: [String] = []
  ) {
    self.appName = appName
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
      && [appName, windowTitle, fieldLabel, priorText, selectedText].allSatisfy {
        $0.trimmedNonEmpty() == nil
      }
  }
}
