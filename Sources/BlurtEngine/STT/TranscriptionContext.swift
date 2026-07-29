/// Per-utterance snapshot of where the dictation is going, gathered at
/// dictation start from the focused app and field. `TranscriptionSteering.build`
/// renders only the parts the request uses — the prior text (as
/// `conversation_context`) and the key terms (as `keyterms_prompt`). Nothing
/// identifying the destination app is sent. The prior text and window title
/// also steer the injector's paste separator; nothing else is consumed, and the
/// rest of the context is neither sent nor logged.
///
/// Every focus field is optional and best-effort: whatever couldn't be read is
/// `nil`, and an entirely empty context customizes nothing (the server applies
/// its own defaults).
public struct TranscriptionContext: Sendable, Equatable {
  /// The frontmost application's display name (e.g. "Slack", "Xcode"). Never
  /// sent.
  public let appName: String?

  /// The focused window's title (e.g. "main.py — blurt", a document name, a
  /// Slack channel). Never sent. Read only to anchor the injector's same-window
  /// separator fallback.
  public let windowTitle: String?

  /// A short label for the focused field (placeholder/title/role, e.g. "To",
  /// "Subject", "Search", "Message"). Never sent.
  public let fieldLabel: String?

  /// Text immediately preceding the insertion point in the focused field. Sent
  /// as the single `conversation_context` turn, so the model knows what the
  /// utterance continues; it also drives the injector's leading-separator
  /// decision. Skipped entirely in secure fields by `FocusCapture`, so a
  /// password never reaches this field.
  public let priorText: String?

  /// The text currently selected in the focused field, when any. Never sent: the
  /// paste replaces it, so priming the model with it would condition the
  /// transcription on text that is on its way out.
  public let selectedText: String?

  /// User-configured domain vocabulary (names, jargon, product names), sent as
  /// `keyterms_prompt` so the model favors these spellings. Unlike the other
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
