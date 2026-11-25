import Foundation

/// The one readiness record: what the app knows about its listening window,
/// written on every transition and renewed by the heartbeat. The keyboard
/// decides between a press and a hop from this and nothing else.
package nonisolated struct ListeningState: Codable, Sendable, Equatable {
  package nonisolated enum Window: String, Codable, Sendable {
    case closed
    case opening
    case open
    case interrupted
    case closing
  }

  /// What keeps the mic closed between dictations, when anything does.
  package nonisolated enum Idle: String, Codable, Sendable {
    /// The mic stays open for the window (the orange dot too).
    case held
    /// A Picture in Picture keeper holds the process's foreground role; the
    /// mic opens per dictation.
    case pip
  }

  package static let contractVersion = 1
  /// How long a record counts the app as there: renewed every
  /// `BlurtShared.appHeartbeatInterval`, never `distantFuture`.
  package static let lease: TimeInterval = 15

  package let version: Int
  /// One per app process; `DictationCoordinator.start()` writes a fresh one.
  package let launchID: UUID
  /// Monotonic per launch, bumped on every publish.
  package let sequence: UInt64
  package let window: Window
  package let idle: Idle
  /// "A press will record now": the source is running and not interrupted
  /// (held), or the keeper is alive (pip). Re-derived every heartbeat.
  package let micLive: Bool
  package let leaseUntil: Date
  /// The window's end; nil = until stopped (`windowMinutes` 0).
  package let windowUntil: Date?
  /// A dictation is in flight.
  package let utterance: Bool
  /// Why a press would not record, when it would not.
  package let reason: FailureReason?
  package let writtenAt: Date

  package init(
    launchID: UUID,
    sequence: UInt64,
    window: Window,
    idle: Idle = .held,
    micLive: Bool = false,
    windowUntil: Date? = nil,
    utterance: Bool = false,
    reason: FailureReason? = nil,
    writtenAt: Date = Date()
  ) {
    version = Self.contractVersion
    self.launchID = launchID
    self.sequence = sequence
    self.window = window
    self.idle = idle
    self.micLive = micLive
    leaseUntil = writtenAt.addingTimeInterval(Self.lease)
    self.windowUntil = windowUntil
    self.utterance = utterance
    self.reason = reason
    self.writtenAt = writtenAt
  }

  /// The record a fresh launch writes before anything else: no window, no lease to speak of.
  package static func launched(_ launchID: UUID = UUID(), at now: Date = Date()) -> Self {
    Self(launchID: launchID, sequence: 0, window: .closed, reason: .sessionOff, writtenAt: now)
  }

  /// A press sent now would record.
  package func isReady(now: Date = Date()) -> Bool {
    window == .open && micLive && leaseUntil > now
  }

  /// Why a press would not record, as the keyboard should say it; nil when ready.
  package func notReady(now: Date = Date()) -> FailureReason? {
    if isReady(now: now) {
      return nil
    }
    if leaseUntil <= now {
      return .suspended
    }
    if let reason {
      return reason
    }
    switch window {
    case .closed, .closing:
      return .sessionOff

    case .opening:
      return .opening

    case .interrupted:
      return .interrupted

    case .open:
      return .micBusy
    }
  }

  /// The same record a beat later: the lease renewed, `micLive` re-read.
  package func renewed(micLive: Bool, at now: Date = Date()) -> Self {
    Self(
      launchID: launchID,
      sequence: sequence + 1,
      window: window,
      idle: idle,
      micLive: micLive,
      windowUntil: windowUntil,
      utterance: utterance,
      reason: reason,
      writtenAt: now
    )
  }
}
