import Foundation

// The failure half of the developer-mode log: every dictation that ends in
// `.failed` is appended to a sibling `errors.jsonl`. Split from
// `DictationLog.swift` (same enum, so both halves share the serial queue, the
// encoder, and `appendLine`) because the two files answer different questions —
// "what did users say" versus "what broke".
//
// A separate file rather than extra fields on the transcript entry: the
// dictations log is a prompt-iteration corpus whose every line is expected to
// carry a `transcript`, and interleaving transcript-less error rows would break
// anything decoding it.
extension DictationLog {
  struct ErrorEntry: Encodable {
    /// Stable case label (`BlurtError.diagnosticName`) — the field to aggregate
    /// on, since `error` below is rewordable human-facing copy.
    let kind: String
    /// The full user-facing description, including the wrapped error's own
    /// `localizedDescription` — for `.sttFailed` that's where the AssemblyAI
    /// status code and server message land.
    let error: String
    let ts: String
    /// Focused-app name at press time, when one was captured. Which app was
    /// targeted is most of the diagnosis for `.targetAppLost` and
    /// `.accessibilityPermissionMissing`.
    let app: String?
    /// Focused-window title at press time, when one was captured.
    let window: String?
    /// Focused-field label at press time, when one was captured.
    let field: String?
    // Deliberately no `prior`/`selected`/`prompt`: the surrounding text the user
    // was editing does nothing to explain a failure, and it's the most sensitive
    // thing the context snapshot holds. Failures are logged from every route
    // (see `DictationSession.setPhase`), including press-time refusals that
    // never involved a transcript, so this log stays diagnostics-only.
  }

  /// Where failures land. Sibling of `defaultURL` in the same directory, so the
  /// one "delete my logs" gesture (`scripts/reset-install.sh`) covers both.
  static let defaultErrorURL = URL.libraryDirectory.appending(path: "Logs/Blurt/errors.jsonl")

  /// `defaultErrorURL` as a home-abbreviated path, for the Developer section's
  /// footer. Derived here next to the URL the writer uses, for the same reason
  /// as `defaultDisplayPath`: the displayed path can't drift from the write
  /// target.
  public static var defaultErrorDisplayPath: String {
    (defaultErrorURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }

  /// Append a failed dictation to the error log. **Gated on developer mode**, so
  /// with the switch off (the default) this returns without touching the disk and
  /// the caller can invoke it unconditionally. The file I/O is dispatched onto
  /// `queue` so it never blocks the `DictationSession` actor mid-failure.
  ///
  /// `store` and `url` exist to be overridden by tests, exactly as on `append`:
  /// with both hard-coded, the gate could only be exercised by writing to the
  /// real `~/Library/Logs`.
  static func appendError(
    _ error: BlurtError,
    context: TranscriptionContext? = nil,
    store: DeveloperModeStore = DeveloperModeStore(),
    to url: URL = defaultErrorURL
  ) {
    guard store.isEnabled else { return }
    let now = Date()
    queue.async {
      writeError(error, context: context, to: url, now: now)
    }
  }

  /// One error entry as a value — the diagnostics-only projection of a failure
  /// plus its context. Split from `writeError` for the same reason as
  /// `makeEntry`: this is where the privacy rule lives (no `prior`, `selected`
  /// or `prompt` field exists to fill), and asserting it on the value proves the
  /// text is absent, where the old `!line.contains("hunter2")` over a temp file
  /// also passed when nothing had been written at all.
  static func makeErrorEntry(
    _ error: BlurtError, context: TranscriptionContext?, now: Date
  ) -> ErrorEntry {
    ErrorEntry(
      kind: error.diagnosticName,
      // Every `BlurtError` supplies an `errorDescription`; the fallback is only
      // so a future case that forgets one logs *something* rather than "".
      error: error.errorDescription ?? String(describing: error),
      ts: now.formatted(timestampFormat),
      app: context?.appName, window: context?.windowTitle, field: context?.fieldLabel)
  }

  /// The unconditional writer, named distinctly from `appendError` for the same
  /// reason `write` is: the gated entry point above must not be bypassable by
  /// accidentally satisfying a different signature.
  static func writeError(
    _ error: BlurtError, context: TranscriptionContext? = nil, to url: URL, now: Date
  ) {
    appendLine(makeErrorEntry(error, context: context, now: now), to: url)
  }
}
