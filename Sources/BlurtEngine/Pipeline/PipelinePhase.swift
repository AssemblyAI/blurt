import Foundation

public enum PipelinePhase: Equatable, Sendable {
  case idle
  /// The press was accepted and the mic is being opened, but no audio is being
  /// captured yet. Claimed *before* `mic.start()` so the overlay answers the
  /// keypress immediately instead of at whatever moment the hardware route
  /// finishes coming up — on a Bluetooth input that is hundreds of milliseconds,
  /// sometimes over a second, of a press that looked like it did nothing.
  ///
  /// Deliberately distinct from `.recording` rather than folded into it: the
  /// projections below present it as "starting", never as live capture, which
  /// keeps the rule that **the UI never claims audio is being recorded before it
  /// is**. Non-terminal, so a second press during it is refused like one during
  /// `.recording`.
  case starting
  case recording
  case transcribing
  case injecting
  case failed(BlurtError)
  case cancelled
  /// Transcription succeeded and the text was pasted into the focused field. A
  /// terminal, non-error outcome — the overlay shows a quiet "pasted" notice as
  /// the mirror of `.noTarget`'s "copied" notice before settling back to idle.
  case pasted
  /// Transcription succeeded but the paste had nowhere to land — no editable
  /// field was focused, or the target app quit/refused activation — so the text
  /// was left on the clipboard. A terminal, non-error outcome — the overlay
  /// shows a quiet "copied" notice rather than the red failure flash.
  case noTarget

  /// Whether the dictation has finished (or never started) — nothing in flight.
  ///
  /// Exhaustive (no `default:`) so adding a phase is a compile error here rather
  /// than a silent "not terminal" — the same reason `menuBarStatus` lists every
  /// case. A phase wrongly reading as non-terminal strands the trigger's gate,
  /// swallowing the user's next press.
  public var isTerminal: Bool {
    switch self {
    case .idle, .failed, .cancelled, .pasted, .noTarget: true
    case .starting, .recording, .transcribing, .injecting: false
    }
  }

  /// Whether this phase is part of a live capture attempt — the mic is open, or
  /// on its way to being open.
  ///
  /// The single definition of "a dictation is being captured right now", so the
  /// consumers that key off it can't drift apart. Today that's `RecordingCueGate`
  /// (the start chime fires on the *press*, i.e. entering `.starting`, so the
  /// user hears the app respond at key-down rather than after the route comes
  /// up). Internal: nothing outside the engine asks, and `.periphery.yml` runs
  /// with `retain_public: false`.
  ///
  /// Exhaustive for the same reason as `isTerminal`.
  var isCapturing: Bool {
    switch self {
    case .starting, .recording: true
    case .idle, .transcribing, .injecting, .failed, .cancelled, .pasted, .noTarget: false
    }
  }

  /// The blocker behind this phase when it represents an unfinished **setup**
  /// step rather than a fault — something the user must go and fix, not a
  /// dictation that broke. Nil for every other phase and every genuine failure.
  ///
  /// Owned here so the classification exists once. Two consumers act on it and
  /// they must agree: `overlayState` renders it as calm `.idle` (no red flash on
  /// the way to the fix), and the host routes it to whatever surfaces setup. When
  /// both re-derived it by pattern-matching `.failed(.apiKeyMissing)`, adding a
  /// second blocker — a press-time mic-permission check is the obvious next one —
  /// meant remembering both sites, and missing either gives a red flash with no
  /// route to the fix, or a press that silently does nothing.
  public var setupBlocker: BlurtError? {
    guard case .failed(let error) = self, error.isSetupBlocker else { return nil }
    return error
  }
}

extension BlurtError {
  /// True for errors that mean "setup isn't finished" rather than "dictation
  /// failed". Internal: hosts ask `PipelinePhase.setupBlocker`, which is the form
  /// they actually need.
  ///
  /// Exhaustive for the same reason as `PipelinePhase.isTerminal`: a new error
  /// that *is* a setup step must not default to "genuine failure", which shows a
  /// red flash with no route to the fix.
  var isSetupBlocker: Bool {
    switch self {
    case .apiKeyMissing: true
    case .accessibilityPermissionMissing, .sttFailed, .targetAppLost, .audioCaptureFailed,
      .noEditableTarget:
      false
    }
  }
}

extension BlurtError: Equatable {
  public static func == (lhs: BlurtError, rhs: BlurtError) -> Bool {
    switch (lhs, rhs) {
    case (.accessibilityPermissionMissing, .accessibilityPermissionMissing),
      (.apiKeyMissing, .apiKeyMissing),
      (.targetAppLost, .targetAppLost),
      (.noEditableTarget, .noEditableTarget):
      return true
    case (.sttFailed(let lhsUnderlying), .sttFailed(let rhsUnderlying)),
      (.audioCaptureFailed(let lhsUnderlying), .audioCaptureFailed(let rhsUnderlying)):
      // Compare wrapped errors by their bridged NSError identity (domain + code)
      // rather than `localizedDescription`. The description is human-facing copy:
      // comparing it would make equality silently depend on message wording, so a
      // localization or phrasing tweak could break a test. Domain + code is the
      // stable identity of the underlying error.
      let lhsError = lhsUnderlying as NSError
      let rhsError = rhsUnderlying as NSError
      return lhsError.domain == rhsError.domain && lhsError.code == rhsError.code
    default:
      return false
    }
  }
}
