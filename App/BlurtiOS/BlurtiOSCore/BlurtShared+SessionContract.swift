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

  /// The window is open and the app can go back to the host: at once under
  /// a held mic, or once the Picture in Picture keeper is up, which it is
  /// within this of the window opening — past it the app goes back anyway,
  /// and the keeper starts from the inline layer as the app leaves
  /// (`PictureInPictureKeeper`).
  package static let hopReturnCap: TimeInterval = 1.5

  package static let fullAccessNeed = "fullAccess"

  /// `blurt://start?reason=<FailureReason>&host=<bundle id>`: the keyboard's
  /// hop, saying why, and from which app (`HostApp.bundleID`), so the app can
  /// bring that one back once the window is open (`HopReturn`).
  package static func startURL(reason: FailureReason?, host: String? = nil) -> URL {
    var components = URLComponents()
    components.scheme = urlScheme
    components.host = startHost
    var items: [URLQueryItem] = []
    if let reason { items.append(URLQueryItem(name: "reason", value: reason.rawValue)) }
    if let trimmedHost = host.trimmedNonEmpty() { items.append(URLQueryItem(name: "host", value: trimmedHost)) }
    if !items.isEmpty { components.queryItems = items }
    // A scheme, a host and query items from an enum's raw value and a bundle
    // id always form a URL; the fallback is the bare start link.
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

  package static func isStart(_ url: URL) -> Bool {
    url.scheme == urlScheme && url.host() == startHost
  }

  package static func isSetup(_ url: URL) -> Bool {
    url.scheme == urlScheme && url.host() == setupHost
  }

  /// The reason a `startURL` carried, if any.
  package static func hopReason(_ url: URL) -> FailureReason? {
    query(url, "reason").flatMap(FailureReason.init(rawValue:))
  }

  /// The host app a `startURL` came from, if the keyboard knew it.
  package static func hopHost(_ url: URL) -> String? {
    query(url, "host").trimmedNonEmpty()
  }

  private static func query(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
  }
}

nonisolated extension SharedStore {
  // MARK: The records

  package var listeningState: ListeningState? {
    get { read(ListeningState.self, forKey: BlurtShared.Key.listeningState) }
    nonmutating set {
      if let newValue {
        write(newValue, forKey: BlurtShared.Key.listeningState)
      } else {
        remove(forKey: BlurtShared.Key.listeningState)
      }
    }
  }

  package var commandAck: CommandAck? {
    get { read(CommandAck.self, forKey: BlurtShared.Key.ack) }
    nonmutating set {
      if let newValue {
        write(newValue, forKey: BlurtShared.Key.ack)
      } else {
        remove(forKey: BlurtShared.Key.ack)
      }
    }
  }

  package var keyboardPresence: KeyboardPresenceRecord? {
    read(KeyboardPresenceRecord.self, forKey: BlurtShared.Key.keyboardPresence)
  }

  /// Writes the record and signals it.
  package func publish(_ state: ListeningState) {
    listeningState = state
    post(BlurtShared.Signal.state)
  }

  /// Writes the ack and signals it.
  package func acknowledge(_ ack: CommandAck) {
    commandAck = ack
    post(BlurtShared.Signal.ack)
  }

  /// Writes the presence record. A keyboard leaving writes `onScreen: false`
  /// only over its own record (`ifOwnedBy`), never over another process's —
  /// as read the moment before: UserDefaults has no compare-and-write, so a
  /// record landing in between is written over, and `OwnerWatchdog` gives its
  /// keyboard the beats to put it back. Returns whether it was written.
  @discardableResult
  package func writeKeyboardPresence(_ record: KeyboardPresenceRecord, ifOwnedBy owner: String? = nil) -> Bool {
    if let owner, let current = keyboardPresence, current.processID != owner {
      return false
    }
    write(record, forKey: BlurtShared.Key.keyboardPresence)
    return true
  }

  /// The keyboard process on screen now, if any.
  package func keyboardOnScreen(now: Date = Date()) -> KeyboardPresenceRecord? {
    guard let record = keyboardPresence, record.onScreen, record.isFresh(now: now) else {
      return nil
    }
    return record
  }
}
