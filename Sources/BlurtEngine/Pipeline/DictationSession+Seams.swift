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
  /// Bundled into one value rather than four initializer parameters: the log
  /// seams have no business on the public initializer, so the whole set rides
  /// on the internal one, and one required parameter there keeps the two
  /// initializers unambiguous at every call site. The focus half *is* public —
  /// as `HostFocusCapture`, below — because a host on another platform has to
  /// supply it: the production defaults here are Accessibility reads, and only
  /// macOS has those.
  ///
  /// Spelled with `var` properties: the synthesized memberwise initializer omits
  /// `let` properties that already carry a default value, so a test could not
  /// substitute one. Each `Seams` value is still immutable in practice — the
  /// session stores one and never writes to it.
  struct Seams: Sendable {
    /// Captures the frontmost application — the paste target, and the context's
    /// app name. On the main actor because it's an AppKit read. Off macOS there
    /// is no frontmost app to read (a keyboard cannot see its host), so the
    /// default reports nothing and a host with real context supplies its own.
    var captureFrontmost: @Sendable () async -> CapturedFocus? = {
      #if os(macOS)
        return await MainActor.run { FocusCapture.captureFrontmost() }
      #else
        return nil
      #endif
    }

    /// Reads the focused field's Accessibility context. Deliberately
    /// synchronous: `performPress` runs it on a Dispatch queue precisely because
    /// it blocks a thread against an unresponsive app (see its call site), and
    /// that stays true of the production capture behind this seam. Off macOS
    /// the default reads nothing; an iPhone host hands the keyboard's text
    /// before the cursor in through `HostFocusCapture` instead.
    var captureFieldContext: @Sendable () -> FocusedFieldContext = {
      #if os(macOS)
        return FocusCapture.captureFieldContext()
      #else
        return .empty
      #endif
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
    /// passes when the host supplies no `HostFocusCapture`, and the only value
    /// production on macOS ever uses.
    static let production = Seams()
  }

  // periphery:ignore - public for hosts outside this repo (the iOS app); the Mac app relies on the defaults.
  /// What a host that is not this repo's Mac app knows about the field being
  /// dictated into, supplied to the public initializer in place of the
  /// Accessibility reads the engine performs on macOS.
  ///
  /// `field` is read once per press, off the actor, and consumed when the
  /// upload opens (bounded by `contextWaitBudget`) — the same contract the
  /// Accessibility capture has, so a host's read may block briefly but must
  /// never hang. An iPhone keyboard's `documentContextBeforeInput` is the
  /// `priorText` the request's `stt_prompt` continues from; everything a
  /// keyboard cannot see stays nil. `frontmost` is the paste target handed to
  /// `InjectorProtocol.setTarget`; a host with no such notion returns nil.
  public struct HostFocusCapture: Sendable {
    public var frontmost: @Sendable () async -> CapturedFocus?
    public var field: @Sendable () -> FocusedFieldContext

    public init(
      frontmost: @escaping @Sendable () async -> CapturedFocus?,
      field: @escaping @Sendable () -> FocusedFieldContext
    ) {
      self.frontmost = frontmost
      self.field = field
    }
  }
}

extension DictationSession.Seams {
  /// The production seams with the focus half replaced by the host's. In an
  /// extension so the struct keeps its memberwise initializer, which the tests
  /// build their seams with.
  init(hostFocusCapture host: DictationSession.HostFocusCapture) {
    self.init(captureFrontmost: host.frontmost, captureFieldContext: host.field)
  }
}
