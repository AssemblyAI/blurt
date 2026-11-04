import Foundation

// MARK: - The session contract
//
// The records the app and the keyboard exchange about the listening window —
// whether a press will record right now, what became of each command, and who
// is on screen. Every type is `nonisolated`, `Codable` and `Sendable`: both
// targets default their declarations to the main actor, but these cross into
// the app's capture path and the keyboard's observers. Every rule here is a
// number the DESIGN.md "two processes" table names.

/// Why the keyboard's press can't record right now — published by the app in
/// `ListeningState.reason` and in a refused `CommandAck`, derived by the
/// keyboard for the two it can only see itself. The keyboard shows one line
/// per reason (`VoiceNotice`) and hops with it (`BlurtShared.startURL`).
package nonisolated enum FailureReason: String, Codable, Sendable, Equatable, CaseIterable {
  /// No window: the session is off (the switch, expiry, a stop).
  case sessionOff
  /// A window can only open with the app in front.
  case needsForeground
  /// The window is opening; a press a moment later will record.
  case opening
  /// A call, Siri or another app's recording took the microphone; the window
  /// waits to resume.
  case interrupted
  /// The capture session died or another client holds the input.
  case micBusy
  /// The microphone opened but delivered only silence.
  case micSilent
  /// A media-services reset ended the window.
  case mediaReset
  case noKey
  case noConsent
  case micDenied
  case network
  /// Keyboard-derived: the press passed its deadline with no answer.
  case unanswered
  /// Keyboard-derived: the app's lease lapsed, so it is suspended or gone.
  case suspended
}

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
    launchID: UUID, sequence: UInt64, window: Window, idle: Idle = .held, micLive: Bool = false,
    windowUntil: Date? = nil, utterance: Bool = false, reason: FailureReason? = nil, writtenAt: Date = Date()
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
  package static func launched(_ launchID: UUID = UUID(), at now: Date = Date()) -> ListeningState {
    ListeningState(launchID: launchID, sequence: 0, window: .closed, reason: .sessionOff, writtenAt: now)
  }

  /// A press sent now would record.
  package func isReady(now: Date = Date()) -> Bool {
    window == .open && micLive && leaseUntil > now
  }

  /// Why a press would not record, as the keyboard should say it; nil when ready.
  package func notReady(now: Date = Date()) -> FailureReason? {
    if isReady(now: now) { return nil }
    if leaseUntil <= now { return .suspended }
    if let reason { return reason }
    switch window {
    case .closed, .closing: return .sessionOff
    case .opening: return .opening
    case .interrupted: return .interrupted
    case .open: return .micBusy
    }
  }

  /// The same record a beat later: the lease renewed, `micLive` re-read.
  package func renewed(micLive: Bool, at now: Date = Date()) -> ListeningState {
    ListeningState(
      launchID: launchID, sequence: sequence + 1, window: window, idle: idle, micLive: micLive,
      windowUntil: windowUntil, utterance: utterance, reason: reason, writtenAt: now)
  }
}

/// The dictation a phase or a command refers to, and the keyboard process
/// whose press started it — the only one (besides whoever is on screen) that
/// may end it.
package nonisolated struct DictationRef: Codable, Sendable, Equatable {
  package let id: UUID
  package let ownerProcessID: String?

  package init(id: UUID, ownerProcessID: String?) {
    self.id = id
    self.ownerProcessID = ownerProcessID
  }
}

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
    /// Already answered (the keyboard's resend).
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

/// Which keyboard is on screen: one record, compare-and-written by its own
/// process only, so a keyboard leaving in one host can't erase the one that
/// just appeared in another.
package nonisolated struct KeyboardPresenceRecord: Codable, Sendable, Equatable {
  package let processID: String
  package let controllerID: String
  package let pid: Int32
  package let seenAt: Date
  package let onScreen: Bool

  package init(processID: String, controllerID: String, pid: Int32, seenAt: Date = Date(), onScreen: Bool) {
    self.processID = processID
    self.controllerID = controllerID
    self.pid = pid
    self.seenAt = seenAt
    self.onScreen = onScreen
  }

  /// Still counts as present (`BlurtShared.presenceWindow`).
  package func isFresh(now: Date = Date()) -> Bool {
    now.timeIntervalSince(seenAt) < SharedStore.presenceWindow
  }
}

nonisolated extension BlurtShared {
  // `nonisolated`: both targets default declarations to the main actor; the
  // keyboard's observers and the app's capture path read these anywhere.
  /// A press with no ack by then is unanswered: the gate resets and the
  /// next tap hops. One resend goes out at `KeyboardModel.commandRetryDelay`.
  package static let pressDeadline: TimeInterval = 1.2
  /// A stop with no ack by then: the app's watchdog ends the dictation.
  package static let stopDeadline: TimeInterval = 1.2
  /// The owner keyboard's presence older than this while a dictation is in
  /// flight → the app releases it (two keyboard beats plus grace).
  package static let ownerWatchdog: TimeInterval = 10
  /// How long the app holds a background task around a release → terminal.
  package static let releaseBackgroundTask: TimeInterval = 25

  package static let setupHost = "setup"

  /// `blurt://start` with nothing else — what every hop falls back to.
  private static var startLink: URL {
    var components = URLComponents()
    components.scheme = urlScheme
    components.host = startHost
    // `URLComponents` with a scheme and a host alone cannot fail to form a URL.
    return components.url ?? URL(fileURLWithPath: "/")
  }

  /// `blurt://start?reason=<FailureReason>`: the keyboard's hop, saying why.
  package static func startURL(reason: FailureReason?) -> URL {
    var components = URLComponents()
    components.scheme = urlScheme
    components.host = startHost
    if let reason { components.queryItems = [URLQueryItem(name: "reason", value: reason.rawValue)] }
    // A scheme, a host and one query item from an enum's raw value always
    // form a URL; the fallback is the bare start link.
    return components.url ?? startLink
  }

  /// `blurt://setup?need=fullAccess`: the keyboard can't dictate until the
  /// app's setup is finished, so no window is opened.
  package static func setupURL(need: String) -> URL {
    var components = URLComponents()
    components.scheme = urlScheme
    components.host = setupHost
    components.queryItems = [URLQueryItem(name: "need", value: need)]
    return components.url ?? startLink
  }

  package static let fullAccessNeed = "fullAccess"

  package static func isStart(_ url: URL) -> Bool {
    url.scheme == urlScheme && url.host() == startHost
  }

  package static func isSetup(_ url: URL) -> Bool {
    url.scheme == urlScheme && url.host() == setupHost
  }

  /// The reason a `startURL` carried, if any.
  package static func hopReason(_ url: URL) -> FailureReason? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == "reason" }?.value.flatMap(FailureReason.init(rawValue:))
  }
}

nonisolated extension SharedStore {
  // MARK: The records

  package static var listeningState: ListeningState? {
    get { read(ListeningState.self, forKey: BlurtShared.Key.listeningState) }
    set {
      if let newValue { write(newValue, forKey: BlurtShared.Key.listeningState) } else {
        remove(forKey: BlurtShared.Key.listeningState)
      }
    }
  }

  /// Writes the record and signals it.
  package static func publish(_ state: ListeningState) {
    listeningState = state
    post(BlurtShared.Signal.state)
  }

  package static var commandAck: CommandAck? {
    get { read(CommandAck.self, forKey: BlurtShared.Key.ack) }
    set {
      if let newValue { write(newValue, forKey: BlurtShared.Key.ack) } else { remove(forKey: BlurtShared.Key.ack) }
    }
  }

  /// Writes the ack and signals it.
  package static func acknowledge(_ ack: CommandAck) {
    commandAck = ack
    post(BlurtShared.Signal.ack)
  }

  package static var keyboardPresence: KeyboardPresenceRecord? {
    read(KeyboardPresenceRecord.self, forKey: BlurtShared.Key.keyboardPresence)
  }

  /// Writes the presence record. A keyboard leaving writes `onScreen: false`
  /// only over its own record (`ifOwnedBy`), never over another process's.
  /// Returns whether it was written.
  @discardableResult
  package static func writeKeyboardPresence(_ record: KeyboardPresenceRecord, ifOwnedBy owner: String? = nil) -> Bool {
    if let owner, let current = keyboardPresence, current.processID != owner { return false }
    write(record, forKey: BlurtShared.Key.keyboardPresence)
    return true
  }

  /// The keyboard process on screen now, if any.
  package static func keyboardOnScreen(now: Date = Date()) -> KeyboardPresenceRecord? {
    guard let record = keyboardPresence, record.onScreen, record.isFresh(now: now) else { return nil }
    return record
  }
}
