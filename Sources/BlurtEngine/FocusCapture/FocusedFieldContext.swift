// periphery:ignore - public for hosts outside this repo (the iOS app); the Mac app never names it.
/// Priming read from the focused field at dictation start (see
/// `TranscriptionContext`). Every field is best-effort: any signal that can't be
/// read is `nil`, and a fully-empty result simply means less context, never an
/// error.
///
/// On macOS `FocusCapture.captureFieldContext` fills it from Accessibility. A
/// host on another platform builds it from whatever its own text surface
/// exposes — an iPhone keyboard's `documentContextBeforeInput` is `priorText`,
/// its `selectedText` is `selectedText`, and the app name, window title and
/// field label stay nil because a keyboard cannot see them — and hands it to
/// `DictationSession` through `HostFocusCapture`.
public struct FocusedFieldContext: Sendable {
  /// A readable field with nothing in it: no signals, and not secure.
  public static let empty = Self(
    priorText: nil, selectedText: nil, windowTitle: nil, fieldLabel: nil
  )

  /// No focused element could be reached, so nothing is known about the field —
  /// including whether it is a password input (`securityUnknown`). An Electron
  /// app's login form is as invisible to Accessibility as its chat box, so the
  /// dictation is kept for the Recent list but never replayed in `stt_prompt`.
  /// A host whose field is knowably not secure (an iPhone keyboard, which the
  /// system swaps out for secure entry) reports `.empty` or its own read instead.
  public static let unreachable = Self(
    priorText: nil, selectedText: nil, windowTitle: nil, fieldLabel: nil, securityUnknown: true
  )

  /// Text immediately preceding the insertion point ("prior chunk context").
  public let priorText: String?
  /// The text currently selected in the focused field — the dictation will
  /// replace it, so it primes the model on what the utterance is about.
  public let selectedText: String?
  /// The focused window's title — a dense topic hint.
  public let windowTitle: String?
  /// A short label for the focused field ("To", "Search", "Message").
  public let fieldLabel: String?
  /// Whether `mustRedactContents` refused to read this field — a password input,
  /// or an element whose role couldn't be read at all (that guard fails closed).
  /// `priorText`/`selectedText` are always nil when this is true, but the flag is
  /// carried separately because "we read nothing" and "we refused to read"
  /// license different downstream behaviour: only the latter means the transcript
  /// the user is about to dictate must not be remembered as history (see
  /// `DictationSession.recentDictations`).
  ///
  /// Defaults to `false` so a test fixture describes an ordinary field without
  /// restating it; the production capture always passes its real verdict.
  public var isSecure: Bool
  /// Whether no focused element could be reached to ask at all (`.unreachable`),
  /// so nothing is known about the field — including whether it is a password
  /// input. Distinct from `isSecure`: a known password field is kept out of
  /// history entirely, while an unknown one is still remembered for the Recent
  /// list but never replayed in a later request (`RecentDictations.Entry.replayable`).
  public var securityUnknown: Bool

  public init(
    priorText: String?,
    selectedText: String?,
    windowTitle: String?,
    fieldLabel: String?,
    isSecure: Bool = false,
    securityUnknown: Bool = false
  ) {
    self.priorText = priorText
    self.selectedText = selectedText
    self.windowTitle = windowTitle
    self.fieldLabel = fieldLabel
    self.isSecure = isSecure
    self.securityUnknown = securityUnknown
  }
}
