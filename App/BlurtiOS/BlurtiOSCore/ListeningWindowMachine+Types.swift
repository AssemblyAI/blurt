import Foundation

// MARK: - The machine's vocabulary
//
// The causes, states, events and effects `ListeningWindowMachine` is written
// in. Values only: every one is `Sendable` and `Equatable`, so a test states
// a row as "this event, in this state, lands here and asks for these".

extension ListeningWindowMachine {
  /// Why a window is closing or closed: for the log, and for the closed record's reason.
  package nonisolated enum Cause: Sendable, Equatable {
    case expiry
    case stop
    case interrupted
    case died
    case openFailed
    case mediaReset
    /// A hop landed while the source was closing: the closing record says
    /// `opening`, and `closed` reopens instead of resting.
    case reopen

    /// How the closed record says it.
    package var reason: FailureReason {
      switch self {
      case .expiry, .stop: .sessionOff
      case .interrupted: .interrupted
      case .died, .openFailed: .micBusy
      case .mediaReset: .mediaReset
      case .reopen: .opening
      }
    }
  }

  package nonisolated enum State: Sendable, Equatable {
    case closed
    case opening(Generation)
    case open(Generation, idle: ListeningState.Idle, utterance: Bool)
    /// `resumable`: a poll when the interruption ends may bring the source
    /// back. False once a resume has failed; then only the next foreground
    /// tries again.
    case interrupted(Generation, reason: FailureReason, resumable: Bool)
    case closing(Generation, cause: Cause)

    package var generation: Generation? {
      switch self {
      case .closed: nil
      case .opening(let gen), .open(let gen, _, _), .interrupted(let gen, _, _), .closing(let gen, _): gen
      }
    }

    package var window: ListeningState.Window {
      switch self {
      case .closed: .closed
      case .opening: .opening
      case .open: .open
      case .interrupted: .interrupted
      case .closing: .closing
      }
    }

    /// The source is open: the only state in which a press records.
    package var isOpen: Bool {
      if case .open = self { true } else { false }
    }

    /// A dictation is in flight.
    package var utterance: Bool {
      if case .open(_, _, true) = self { true } else { false }
    }

    /// Why a press would not record, as the record says it; nil while open.
    package var reason: FailureReason? {
      switch self {
      case .closed: .sessionOff
      case .opening: .opening
      case .open: nil
      case .interrupted(_, let reason, _): reason
      case .closing(_, let cause): cause.reason
      }
    }
  }

  /// What happened. Events about the source carry the generation they are about;
  /// the app's own (`openRequested`, `closeRequested`, `foregrounded`,
  /// `windowMinutesChanged`) carry none.
  package nonisolated enum Event: Sendable, Equatable {
    /// The keyboard's hop or the app's own switch asking for a window.
    /// `inForeground` is the interpreter's `applicationState != .background`:
    /// a hop lands while the app is still `.inactive`, and iOS lets capture
    /// start from there, so only `.background` is refused.
    case openRequested(inForeground: Bool)
    case opened(Generation)
    case openFailed(Generation, FailureReason)
    case utteranceStarted(Generation)
    case utteranceEnded(Generation)
    case interruptionBegan(Generation, FailureReason)
    case interruptionEnded(Generation, shouldResume: Bool)
    /// The app came to the front; `turnedOff` is the session switch's word.
    case foregrounded(turnedOff: Bool)
    case resumed(Generation)
    case resumeFailed(Generation, FailureReason)
    case sourceDied(Generation, FailureReason)
    case mediaReset(Generation)
    case expired(Generation)
    case closeRequested
    case closed(Generation)
    case idleChanged(Generation, ListeningState.Idle)
    /// Settings changed `SharedStore.windowMinutes`: the new length applies
    /// to the window that is open, not only the next one.
    case windowMinutesChanged(Int)

    package var generation: Generation? {
      switch self {
      case .openRequested, .foregrounded, .closeRequested, .windowMinutesChanged: nil
      case .opened(let gen), .openFailed(let gen, _), .utteranceStarted(let gen), .utteranceEnded(let gen),
        .interruptionBegan(let gen, _), .interruptionEnded(let gen, _), .resumed(let gen), .resumeFailed(let gen, _),
        .sourceDied(let gen, _), .mediaReset(let gen), .expired(let gen), .closed(let gen), .idleChanged(let gen, _):
        gen
      }
    }
  }

  /// What to do about it, in order. The interpreter owns the audio session, the
  /// source, the timers, the background task and the store; this only names it.
  package nonisolated enum Effect: Sendable, Equatable {
    case activateSession
    case openSource(Generation)
    /// `mayStart`: the app is in front, so the source may be started outright;
    /// otherwise only reactivate and poll for it coming back on its own.
    case tryResume(Generation, mayStart: Bool)
    /// The dictation in flight ends: released with its words, or cancelled.
    case endUtterance(keepWords: Bool)
    case closeSource(Generation)
    /// `skipIfInterrupted`: deactivating during a call throws, so leave it.
    case deactivateSession(skipIfInterrupted: Bool)
    /// Replaces the expiry timer that is running, if one is.
    case scheduleExpiry(Date, Generation)
    case cancelExpiry
    case beginBackgroundTask
    /// Ends the background task if one is held; nothing otherwise.
    case endBackgroundTask
    case publish(ListeningState)
    case log(String)
  }
}
