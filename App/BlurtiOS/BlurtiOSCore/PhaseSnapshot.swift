import BlurtEngine
import Foundation

/// What the keyboard shows while the app works: the pipeline's phase, flattened
/// to what the orb can show, plus the live microphone level.
package nonisolated struct PhaseSnapshot: Codable, Sendable, Equatable {
  package nonisolated enum State: String, Codable, Sendable {
    case idle
    case connecting
    case recording
    case processing
    case pasted
    case copied
    case error
  }

  package static let idle = Self(state: .idle, message: nil, level: 0, at: .distantPast)

  /// How long the words-landed notice stays on the orb before it settles back
  /// to idle: the Mac's 0.8 s, a little longer since a phone has no hover to
  /// reveal more (DESIGN.md › The two processes: notice dwell).
  package static let pastedDwell: TimeInterval = 1.2
  /// And the copied and error notices, the Mac's 1.6 s the same way: the
  /// longest a notice dwells.
  package static let noticeDwell: TimeInterval = 2

  /// The longest notice dwell plus a second of slack.
  package static let noticeStaleAfter: TimeInterval = noticeDwell + 1
  /// The engine's cap on one dictation, plus ten seconds for the transcript
  /// to come back.
  package static let inFlightStaleAfter: TimeInterval = SyncSTTLimits.maxAudioSeconds + 10

  package let state: State
  package let message: String?
  package let level: Double
  package let at: Date
  /// The keyboard command the app last took when it published this — the
  /// press this phase answers, or the release or cancel that ended it. The
  /// keyboard settles its gate only for the press it is waiting on: a notice
  /// from the *previous* dictation landing a moment after a new press must
  /// not read as that press being over.
  package let command: UUID?
  /// Why an `.error` happened, typed, so the keyboard can show one line and
  /// decide whether the next tap hops.
  package let reason: FailureReason?
  /// The press this in-flight phase answers (set when the session accepts
  /// it): a lost ack can't time out a dictation the keyboard can see running.
  package let answers: UUID?
  /// The dictation in flight and its owner.
  package let dictation: DictationRef?
  /// The app process that published this.
  package let launchID: UUID?
  /// When the recording in flight started, for the keyboard's countdown.
  package let recordingSince: Date?

  /// How long this notice stays on the orb before it settles back to idle.
  /// Nil for the states that end on their own.
  package var noticeDwellSeconds: Double? {
    switch state {
    case .pasted:
      Self.pastedDwell

    case .copied, .error:
      Self.noticeDwell

    case .idle, .connecting, .recording, .processing:
      nil
    }
  }

  /// Whether this is too old to show. A notice (pasted, copied, error) dwells
  /// for a moment and is then over; an in-flight state older than the longest
  /// possible dictation belongs to an app that was killed under it. The
  /// keyboard reads the snapshot back on every appearance and on every signal,
  /// including signals held while it was suspended, so it must decide for
  /// itself.
  package var isStale: Bool { isStale(now: Date()) }

  package init(
    state: State,
    message: String?,
    level: Double,
    at: Date,
    command: UUID? = nil,
    reason: FailureReason? = nil,
    answers: UUID? = nil,
    dictation: DictationRef? = nil,
    launchID: UUID? = nil,
    recordingSince: Date? = nil
  ) {
    self.state = state
    self.message = message
    self.level = level
    self.at = at
    self.command = command
    self.reason = reason
    self.answers = answers
    self.dictation = dictation
    self.launchID = launchID
    self.recordingSince = recordingSince
  }

  package func isStale(now: Date) -> Bool {
    let age = now.timeIntervalSince(at)
    switch state {
    case .idle:
      return false

    case .pasted, .copied, .error:
      return age > Self.noticeStaleAfter

    case .connecting, .recording, .processing:
      return age > Self.inFlightStaleAfter
    }
  }
}
