import Foundation

/// The application that was frontmost when the user pressed the trigger — the
/// paste target, and the context's app name.
///
/// A pid and a display name rather than an `NSRunningApplication`, so the value
/// crosses the engine's public seams (`InjectorProtocol.setTarget`,
/// `DictationSession.HostFocusCapture`) on every platform the engine builds
/// for. `KeyInjector` resolves the process handle from the pid on macOS; a host
/// on iOS has no process to name — a keyboard cannot see which app hosts it —
/// and passes nil.
public struct CapturedFocus: Sendable {
  public let pid: pid_t
  public let processName: String?

  public init(pid: pid_t, processName: String?) {
    self.pid = pid
    self.processName = processName
  }
}

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

  public init(
    priorText: String?, selectedText: String?, windowTitle: String?, fieldLabel: String?,
    isSecure: Bool = false
  ) {
    self.priorText = priorText
    self.selectedText = selectedText
    self.windowTitle = windowTitle
    self.fieldLabel = fieldLabel
    self.isSecure = isSecure
  }

  public static let empty = FocusedFieldContext(
    priorText: nil, selectedText: nil, windowTitle: nil, fieldLabel: nil)
}

/// The press-time focus capture. The Accessibility-backed reads live in
/// `FocusCapture.swift` and `FocusCapture+Editability.swift`, which exist on
/// macOS only; the decisions that need no Accessibility call
/// (`FocusCapture+Pure.swift`) build on every platform, which is why the type
/// itself is declared here rather than beside the reads.
enum FocusCapture {}
