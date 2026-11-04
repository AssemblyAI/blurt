import AssemblyAI
import BlurtEngine
import Foundation

// The presence contract and the shared word lists, split out of
// SharedState.swift so the records stay under one roof and the file under
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

  /// Whether the app currently has the microphone open for the keyboard: the
  /// window has not lapsed, and the app is still there to hear — iOS may have
  /// killed it, or a phone call taken the microphone, with the window's end
  /// still in the future. The keyboard then opens the app rather than sending
  /// a press nobody would answer.
  package static var isListening: Bool { isListening(now: Date()) }

  package static func isListening(now: Date) -> Bool {
    // The session record decides when there is one (`ListeningState`); the
    // older keys below answer for a build that has not written one yet.
    if let state = listeningState { return state.isReady(now: now) }
    guard (listeningUntil ?? .distantPast) > now else { return false }
    return now.timeIntervalSince(appSeenAt ?? .distantPast) < presenceWindow
  }

  /// Whether a keyboard is on screen to take the words (see `presenceWindow`).
  package static var isKeyboardPresent: Bool {
    Date().timeIntervalSince(keyboardSeenAt ?? .distantPast) < presenceWindow
  }

  /// Which keyboard process is on screen — a fresh id per process, written
  /// with its heartbeat — so a result can be addressed to it.
  package static var keyboardInstance: String? {
    get { defaults.string(forKey: BlurtShared.Key.keyboardInstance) }
    set { defaults.set(newValue, forKey: BlurtShared.Key.keyboardInstance) }
  }

  // MARK: Key terms

  /// The user's own key terms — names and jargon the request should spell
  /// right — under the engine's own key (`KeyTermsStore.defaultsKey`,
  /// `BlurtKeyTerms`, comma-separated) but in the App Group, so the keyboard
  /// can add one on the spot and the app reads it on the very next press.
  package static var keyTerms: [String] {
    get { KeyTerms.parse(defaults.string(forKey: keyTermsKey) ?? "") }
    set { defaults.set(KeyTerms.join(newValue), forKey: keyTermsKey) }
  }

  /// `BlurtKeyTerms` — spelled out here rather than imported from the engine so
  /// the keyboard, which links it too, and the app can't disagree.
  package static let keyTermsKey = "BlurtKeyTerms"

  /// Adds a term unless it is already there (case-insensitively). Returns
  /// whether the list changed.
  @discardableResult
  package static func addKeyTerm(_ term: String) -> Bool {
    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    var terms = keyTerms
    guard !terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
    terms.append(trimmed)
    keyTerms = terms
    return true
  }

  package static var appSeenAt: Date? {
    get { defaults.object(forKey: BlurtShared.Key.appSeenAt) as? Date }
    set { defaults.set(newValue, forKey: BlurtShared.Key.appSeenAt) }
  }

  package static var keyboardSeenAt: Date? {
    get { defaults.object(forKey: BlurtShared.Key.keyboardSeenAt) as? Date }
    set { defaults.set(newValue, forKey: BlurtShared.Key.keyboardSeenAt) }
  }

  /// When the keyboard last copied the phone's word list into the App Group.
  package static var lexiconRefreshedAt: Date? {
    get { defaults.object(forKey: BlurtShared.Key.lexiconRefreshedAt) as? Date }
    set { defaults.set(newValue, forKey: BlurtShared.Key.lexiconRefreshedAt) }
  }

  /// Set by the keyboard the first time it runs with Full Access — the only
  /// public-API way the app can tell that the keyboard was added and allowed.
  package static var keyboardEverSeen: Bool {
    get { defaults.bool(forKey: BlurtShared.Key.keyboardEverSeen) }
    set { defaults.set(newValue, forKey: BlurtShared.Key.keyboardEverSeen) }
  }

  /// Fires a Darwin notification. Carries nothing: the receiver reads the
  /// payload back out of these defaults.
  package static func post(_ signal: String) {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(signal as CFString), nil, nil, true)
  }
}
