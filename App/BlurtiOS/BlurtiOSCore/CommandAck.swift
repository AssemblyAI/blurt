import Foundation

/// The app's answer to one keyboard command, written under `Key.ack` and
/// posted as `Signal.ack`. A press with no ack by `BlurtShared.pressDeadline`
/// is treated as unanswered by the keyboard: gate reset, next tap hops.
package nonisolated struct CommandAck: Codable, Sendable, Equatable {
  package nonisolated enum Outcome: Codable, Sendable, Equatable {
    /// The press started this dictation.
    case started(UUID)
    /// A dictation was already in flight; the press latched onto it.
    case busy(UUID)
    case stopped(UUID)
    case cancelled(UUID)
    /// The window can't record now; the keyboard shows the reason and hops.
    case notListening(FailureReason)
    /// A release or cancel from a keyboard that neither owns the dictation nor is on screen.
    case notOwner
    /// A release or cancel with nothing in flight.
    case nothingInFlight
    /// Older than `commandFreshnessWindow`.
    case stale
    /// Kept so older acks still decode: the router answers a resend with the
    /// command's original outcome instead (`CommandRouter`).
    case duplicate
  }

  package let commandID: UUID
  package let launchID: UUID
  package let outcome: Outcome
  package let at: Date

  package init(commandID: UUID, launchID: UUID, outcome: Outcome, at: Date = Date()) {
    self.commandID = commandID
    self.launchID = launchID
    self.outcome = outcome
    self.at = at
  }
}
