import BlurtEngine
import Foundation

// The presence contract and the shared word lists, split out of
// BlurtShared.swift so the records stay under one roof and the file under
// swiftlint's length.

nonisolated extension SharedStore {
  // MARK: Presence — the contract between the two processes

  /// Each side writes a timestamp every few seconds while it is there (the app
  /// while its microphone is open, the keyboard while it is on screen), and
  /// the other side counts it present while that timestamp is younger than
  /// the window. The window is more than twice the heartbeat, so one missed
  /// beat — a busy main thread, a suspended process resuming — doesn't read
  /// as absence, while a killed process reads as absent within seconds.
  package static let appHeartbeatInterval: TimeInterval = 5
  package static let keyboardHeartbeatInterval: TimeInterval = 4
  package static let presenceWindow: TimeInterval = 15

  /// `BlurtKeyTerms` — spelled out here rather than imported from the engine so
  /// the keyboard, which links it too, and the app can't disagree.
  package static let keyTermsKey = "BlurtKeyTerms"

  /// Whether the app currently has the microphone open for the keyboard: the
  /// window has not lapsed, and the app is still there to hear — iOS may have
  /// killed it, or a phone call taken the microphone, with the window's end
  /// still in the future. The keyboard then opens the app rather than sending
  /// a press nobody would answer.
  package var isListening: Bool { isListening(now: Date()) }

  /// Which keyboard process is on screen — a fresh id per process, written
  /// with its heartbeat — so a result can be addressed to it.
  package var keyboardInstance: String? {
    get { defaults.string(forKey: BlurtShared.Key.keyboardInstance) }
    nonmutating set { defaults.set(newValue, forKey: BlurtShared.Key.keyboardInstance) }
  }

  // MARK: Key terms

  /// The user's own key terms — names and jargon the request should spell
  /// right — under the engine's own key (`KeyTermsStore.defaultsKey`,
  /// `BlurtKeyTerms`, comma-separated) but in the App Group, so the keyboard
  /// can add one on the spot and the app reads it on the very next press.
  package var keyTerms: [String] {
    get { KeyTermList.parse(defaults.string(forKey: Self.keyTermsKey) ?? "") }
    nonmutating set { defaults.set(KeyTermList.join(newValue), forKey: Self.keyTermsKey) }
  }

  package var appSeenAt: Date? {
    get { defaults.object(forKey: BlurtShared.Key.appSeenAt) as? Date }
    nonmutating set { defaults.set(newValue, forKey: BlurtShared.Key.appSeenAt) }
  }

  package var keyboardSeenAt: Date? {
    get { defaults.object(forKey: BlurtShared.Key.keyboardSeenAt) as? Date }
    nonmutating set { defaults.set(newValue, forKey: BlurtShared.Key.keyboardSeenAt) }
  }

  /// When the keyboard last copied the phone's word list into the App Group.
  package var lexiconRefreshedAt: Date? {
    get { defaults.object(forKey: BlurtShared.Key.lexiconRefreshedAt) as? Date }
    nonmutating set { defaults.set(newValue, forKey: BlurtShared.Key.lexiconRefreshedAt) }
  }

  /// Set by the keyboard the first time it runs with Full Access — the only
  /// public-API way the app can tell that the keyboard was added and allowed.
  package var keyboardEverSeen: Bool {
    get { defaults.bool(forKey: BlurtShared.Key.keyboardEverSeen) }
    nonmutating set { defaults.set(newValue, forKey: BlurtShared.Key.keyboardEverSeen) }
  }

  package func isListening(now: Date) -> Bool {
    // The session record decides when there is one (`ListeningState`); the
    // older keys below answer for a build that has not written one yet.
    if let state = listeningState {
      return state.isReady(now: now)
    }
    guard (listeningUntil ?? .distantPast) > now else {
      return false
    }
    return now.timeIntervalSince(appSeenAt ?? .distantPast) < Self.presenceWindow
  }

  /// Whether a keyboard is on screen to take the words (see `presenceWindow`).
  package func isKeyboardPresent(now: Date) -> Bool {
    now.timeIntervalSince(keyboardSeenAt ?? .distantPast) < Self.presenceWindow
  }

  /// Adds a term unless it is already there (case-insensitively). Returns
  /// whether the list changed.
  @discardableResult
  package func addKeyTerm(_ term: String) -> Bool {
    let terms = keyTerms
    let updated = KeyTermList.appending(term, to: terms)
    guard updated != terms else {
      return false
    }
    keyTerms = updated
    return true
  }

  /// Fires a Darwin notification, under this store's prefix. Carries nothing:
  /// the receiver reads the payload back out of these defaults.
  package func post(_ signal: String) {
    let name = CFNotificationName((signalPrefix + signal) as CFString)
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, true)
  }

  /// Listens for a Darwin notification this store's `post` sends — under the
  /// same prefix, so a scratch store hears only its own. The handler runs on
  /// whichever thread the system delivers on (`DarwinObserver`).
  package func observe(_ signal: String, handler: @escaping @Sendable () -> Void) -> DarwinObserver {
    DarwinObserver(name: signalPrefix + signal, handler: handler)
  }
}
