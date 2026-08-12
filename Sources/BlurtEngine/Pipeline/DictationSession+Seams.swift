extension DictationSession {
  /// The collaborators the session reaches for that aren't protocol seams: the
  /// press-time focus capture and the developer-mode log. Both were called as
  /// module-level statics, which made three things true at once — the captured
  /// context could never be asserted (only its arrival counted, because its value
  /// depended on whichever app happened to be frontmost during the test run),
  /// every press in the suite paid a real main-actor AppKit read plus ~6
  /// synchronous cross-process Accessibility round trips, and the log wrote
  /// through the *real* `DeveloperModeStore` to the *real*
  /// `~/Library/Logs/Blurt`, so on a machine with developer mode switched on
  /// `swift test` appended its fixtures to the user's own dictation corpus.
  ///
  /// Bundled into one value rather than four initializer parameters: the
  /// public initializer can't name these types (`CapturedFocus` and
  /// `FocusedFieldContext` are internal), so the seams ride on the internal
  /// initializer, and one required parameter there keeps the two initializers
  /// unambiguous at every call site.
  ///
  /// Spelled with `var` properties: the synthesized memberwise initializer omits
  /// `let` properties that already carry a default value, so a test could not
  /// substitute one. Each `Seams` value is still immutable in practice — the
  /// session stores one and never writes to it.
  struct Seams: Sendable {
    /// Captures the frontmost application — the paste target, and the context's
    /// app name. On the main actor because it's an AppKit read.
    var captureFrontmost: @Sendable () async -> CapturedFocus? = {
      await MainActor.run { FocusCapture.captureFrontmost() }
    }

    /// Reads the focused field's Accessibility context. Deliberately
    /// synchronous: `performPress` runs it on a Dispatch queue precisely because
    /// it blocks a thread against an unresponsive app (see its call site), and
    /// that stays true of the production capture behind this seam.
    var captureFieldContext: @Sendable () -> FocusCapture.FocusedFieldContext = {
      FocusCapture.captureFieldContext()
    }

    /// Records a completed dictation in the developer-mode log. Gated on the
    /// switch inside `DictationLog.append`, which also dispatches the file I/O
    /// off this actor.
    var logTranscript: @Sendable (String, TranscriptionContext?) -> Void = {
      DictationLog.append(transcript: $0, context: $1)
    }

    /// Records a failure in the sibling error log, from the one place every
    /// failure route funnels through (`setPhase`).
    var logFailure: @Sendable (BlurtError, TranscriptionContext?) -> Void = {
      DictationLog.appendError($0, context: $1)
    }

    /// The real focus capture and the real log — what the public initializer
    /// passes, and the only value production ever uses.
    static let production = Seams()
  }
}
