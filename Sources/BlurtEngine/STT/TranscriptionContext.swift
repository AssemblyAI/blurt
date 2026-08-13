/// Everything captured at dictation start about where the user is typing:
/// the frontmost app, the focused window and field, the text around the cursor,
/// and the user's key terms.
///
/// **Most of it never leaves the machine.** Only `priorText` is rendered into
/// the request `prompt` by `TranscriptionPrompt.build` (and `keyTerms` ride a
/// separate request field). The rest is collected for local work — paste
/// spacing, the injector's window identity, the developer-mode log — and each
/// field below says which it is. A field's presence here is not permission to
/// send it; widening the prompt is a deliberate decision, not a wiring detail.
///
/// Every field is optional: whichever is available is used, and an entirely
/// empty context yields no prompt (the server applies its own default).
public struct TranscriptionContext: Sendable, Equatable {
  /// The frontmost application's display name (e.g. "Slack", "Xcode").
  /// **Local only, not sent**: it identifies the paste target and labels the
  /// developer-mode log entry.
  public let appName: String?

  /// The focused window's title (e.g. "Re: Q3 pricing — Gmail", a document
  /// name, a Slack channel). **Local only, not sent** — it is the most
  /// revealing signal captured. `KeyInjector` uses it to recognize the captured
  /// window (a browser hosts many unrelated tabs under one PID), and the
  /// developer-mode log records it.
  public let windowTitle: String?

  /// A short label for the focused field (placeholder/title/role, e.g. "To",
  /// "Subject", "Search", "Message"). **Local only, not sent**; it appears in
  /// the developer-mode log.
  public let fieldLabel: String?

  /// Text immediately preceding the insertion point in the focused field.
  /// **Sent**, as the request prompt's "prior chunk context", so the transcript
  /// continues naturally from what is already there — the one focus signal that
  /// goes on the wire. Also drives the paste's leading separator.
  public let priorText: String?

  /// The text currently selected in the focused field, when any. Dictating with
  /// a selection replaces it (the paste overwrites the highlighted range).
  /// **Local only, not sent**; it appears in the developer-mode log.
  public let selectedText: String?

  /// User-configured domain vocabulary (names, jargon, product names), sourced
  /// from `KeyTermsStore`. Unlike the other fields this isn't per-utterance
  /// focus state — it's the same list every time. Not part of the prompt: it is
  /// sent as the request's own word-boost field.
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
  /// are no key terms. Covers every signal, including the ones that stay local,
  /// so it answers "is this snapshot worth carrying at all" — not "will this
  /// produce a prompt", which only `priorText` decides.
  public var isEmpty: Bool {
    keyTerms.isEmpty
      && [appName, windowTitle, fieldLabel, priorText, selectedText].allSatisfy {
        $0.trimmedNonEmpty() == nil
      }
  }
}
