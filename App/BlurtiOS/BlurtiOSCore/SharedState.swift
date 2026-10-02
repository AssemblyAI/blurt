import Foundation

// MARK: - The App Group contract

/// What the Blurt app and the Blurt keyboard agree on. They are two processes:
/// the app listens and transcribes (iOS lets no keyboard use the microphone),
/// the keyboard drops the words into the field it is attached to. They talk
/// through the App Group's shared defaults and wake each other with Darwin
/// notifications — a system-wide "something changed" ping that carries no data,
/// so every payload lives in the defaults under one of the keys below.
package nonisolated enum BlurtShared {
  /// The App Group both targets declare. A placeholder namespace inherited from
  /// the Mac app; an org-owned id replaces it before the App Store, and the app
  /// and the keyboard must change together.
  package static let appGroup = "group.dev.alex.blurt"
  /// The URL the keyboard opens to bring the app forward (`blurt://start`) —
  /// the one moment iOS insists on before the microphone may open.
  package static let urlScheme = "blurt"
  package static let startHost = "start"
  /// A press command older than this was held while the app was suspended:
  /// the app drops it unanswered, and the keyboard stops waiting for an answer.
  package static let commandFreshnessWindow: TimeInterval = 10

  package nonisolated enum Key {
    package static let layout = "keyboardLayout"
    package static let autoDictate = "autoDictate"
    package static let theme = "keyboardTheme"
    /// TEMPORARY: which mic concept draws (a, b or c), while the three are
    /// tried in use. Goes with the losers once one is picked.
    package static let voiceElement = "voiceElement"
    /// Where the mic key sits across the keyboard (`MicAlignment`).
    package static let micAlignment = "micAlignment"
    package static let listeningUntil = "listeningUntil"
    package static let windowMinutes = "listeningWindowMinutes"
    package static let phase = "phase"
    package static let command = "command"
    package static let result = "result"
    package static let keyboardSeenAt = "keyboardSeenAt"
    package static let keyboardInstance = "keyboardInstance"
    package static let appSeenAt = "appSeenAt"
    package static let keyboardEverSeen = "keyboardEverSeen"
    package static let lexicon = "lexicon"
    package static let lexiconRefreshedAt = "lexiconRefreshedAt"
  }

  /// Darwin notification names. Reverse-DNS so they can't collide with another
  /// app's on the same device.
  package nonisolated enum Signal {
    package static let command = "dev.alex.blurt.ios.command"
    package static let phase = "dev.alex.blurt.ios.phase"
    package static let result = "dev.alex.blurt.ios.result"
    package static let lexicon = "dev.alex.blurt.ios.lexicon"
  }
}

/// Which keyboard the user chose. All three share the same plumbing underneath;
/// they differ only in how much keyboard sits around the mic.
package nonisolated enum KeyboardLayout: String, CaseIterable, Codable, Sendable, Identifiable {
  /// A slim strip: the mic, delete, return and the globe. Typing letters means
  /// switching back to the system keyboard.
  case slimBar
  /// A big orb with cancel beside it and a few keys — the shape Wispr and
  /// Aqua ship — that swipes to the full keyboard.
  case panel
  /// A complete keyboard with the mic as the main key, so nobody has to switch
  /// keyboards to fix a typo.
  case full

  package var id: String { rawValue }

  package var title: String {
    switch self {
    case .slimBar: "Mic bar"
    case .panel: "Mic panel"
    case .full: "Full keyboard"
    }
  }

  package var summary: String {
    switch self {
    case .slimBar: "Just the mic and a few keys. Switch keyboards to type."
    case .panel: "A big mic with status and cancel. Swipe sideways for the full keyboard, and back."
    case .full: "Every letter key, with the orb above them."
    }
  }
}

// MARK: - Payloads
//
// Every type below is `nonisolated`: both targets default their declarations to
// the main actor (`SWIFT_DEFAULT_ACTOR_ISOLATION`), but these values cross into
// the app's capture path and the engine's closures, which run anywhere.

/// What the keyboard asks the app to do, with the context only the keyboard can
/// see: the text before the cursor primes the transcript exactly as the Mac's
/// Accessibility read does.
package nonisolated struct KeyboardCommand: Codable, Sendable {
  package nonisolated enum Kind: String, Codable, Sendable {
    case press
    case release
    case cancel
  }

  package let id: UUID
  package let kind: Kind
  package let priorText: String?
  package let selectedText: String?
  package let sentAt: Date
  /// The keyboard process that sent it (`KeyboardModel.instanceID`): the
  /// words come back to the field the press was made in, not whichever is up.
  package let keyboard: String?

  /// Young enough for the app to act on. A notification held while the app
  /// was suspended can deliver one from minutes ago, which the app drops
  /// unread — so the keyboard stops waiting for an answer to it, too.
  package func isFresh(now: Date = Date()) -> Bool {
    now.timeIntervalSince(sentAt) < BlurtShared.commandFreshnessWindow
  }
}

/// The words the app got back, for the keyboard to insert. The keyboard joins
/// them onto the live text before the cursor itself (`InsertionSeparator`),
/// since the user may have typed since the press.
package nonisolated struct DictationResult: Codable, Sendable {
  package let id: UUID
  package let text: String
  package let deliveredAt: Date
  /// The keyboard instance the words are for — the one whose heartbeat the
  /// app last saw — so a second live keyboard in another app doesn't also
  /// insert them. Nil means whoever is up.
  package let recipient: String?
}

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

  package init(state: State, message: String?, level: Double, at: Date, command: UUID? = nil) {
    self.state = state
    self.message = message
    self.level = level
    self.at = at
    self.command = command
  }

  package static let idle = PhaseSnapshot(state: .idle, message: nil, level: 0, at: .distantPast)

  /// How long a notice stays on the orb before it settles back to idle — the
  /// Mac's 0.8 s / 1.6 s dwell, a little longer since a phone has no hover to
  /// reveal more. Nil for the states that end on their own.
  package var noticeDwellSeconds: Double? {
    switch state {
    case .pasted: 1.2
    case .copied, .error: 2.0
    case .idle, .connecting, .recording, .processing: nil
    }
  }

  /// Whether this is too old to show. A notice (pasted, copied, error) dwells
  /// for a moment and is then over; an in-flight state older than the longest
  /// possible dictation belongs to an app that was killed under it. The
  /// keyboard reads the snapshot back on every appearance and on every signal,
  /// including signals held while it was suspended, so it must decide for
  /// itself.
  package var isStale: Bool { isStale(now: Date()) }

  package func isStale(now: Date) -> Bool {
    let age = now.timeIntervalSince(at)
    switch state {
    case .idle: return false
    case .pasted, .copied, .error: return age > Self.noticeStaleAfter
    case .connecting, .recording, .processing: return age > Self.inFlightStaleAfter
    }
  }

  /// The longest notice dwell (2 s) plus a second of slack.
  package static let noticeStaleAfter: TimeInterval = 3
  /// The engine's 120 s cap on one dictation, plus ten seconds for the
  /// transcript to come back.
  package static let inFlightStaleAfter: TimeInterval = 130
}

/// One entry of the phone's own word list (`UILexicon`): contact names and the
/// user's text replacements. Names go to the request as key terms so they come
/// back spelled right; replacements are the phone's own text shortcuts.
package nonisolated struct LexiconEntry: Codable, Sendable {
  package let userInput: String
  package let documentText: String

  /// Contact names come through with both fields equal; a text replacement
  /// has a shortcut on one side and its expansion on the other.
  package var isName: Bool { userInput == documentText }
}

// MARK: - Shared defaults

/// Typed access to the App Group's defaults, usable from any thread — the
/// keyboard writes from the main actor, the app's capture path reads from
/// wherever the engine calls it.
package nonisolated enum SharedStore {
  /// The App Group's defaults — what both processes read and write. Falls
  /// back to the process's own only where the group is out of reach (a
  /// keyboard without Full Access), so nothing crashes; nothing is shared then.
  /// Tests point this at a throwaway suite (`override`) so they never touch
  /// the real one.
  package static var defaults: UserDefaults { override ?? shared }
  nonisolated(unsafe) static var override: UserDefaults?
  // `UserDefaults` is thread-safe by contract; the type just isn't marked Sendable.
  nonisolated(unsafe) private static let shared = UserDefaults(suiteName: BlurtShared.appGroup) ?? .standard

  package static func write<Value: Encodable>(_ value: Value, forKey key: String) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: key)
  }

  package static func read<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  package static func remove(forKey key: String) {
    defaults.removeObject(forKey: key)
  }

  package static var layout: KeyboardLayout {
    get { KeyboardLayout(rawValue: defaults.string(forKey: BlurtShared.Key.layout) ?? "") ?? .panel }
    set { defaults.set(newValue.rawValue, forKey: BlurtShared.Key.layout) }
  }

  /// Which keyboard theme (`KeyboardPalette.id`); the iPhone's own until one
  /// is picked.
  package static var themeID: String {
    get { defaults.string(forKey: BlurtShared.Key.theme) ?? "system" }
    set { defaults.set(newValue, forKey: BlurtShared.Key.theme) }
  }

  /// TEMPORARY: the mic concept to draw — `VoiceElementKind.rawValue`, the
  /// shipped one until Settings says otherwise. Read by the keyboard on every
  /// appearance and by the home screen live. Goes with the losers.
  package static var voiceElementKind: VoiceElementKind {
    get { VoiceElementKind(rawValue: defaults.string(forKey: BlurtShared.Key.voiceElement) ?? "") ?? .shipped }
    set { defaults.set(newValue.rawValue, forKey: BlurtShared.Key.voiceElement) }
  }

  /// Where the mic key sits across the keyboard; the middle until chosen.
  package static var micAlignment: MicAlignment {
    get { MicAlignment(rawValue: defaults.string(forKey: BlurtShared.Key.micAlignment) ?? "") ?? .center }
    set { defaults.set(newValue.rawValue, forKey: BlurtShared.Key.micAlignment) }
  }

  /// Hands-free: the keyboard starts a dictation the moment it appears in a
  /// text field, so there is nothing to tap before talking. On by default.
  package static var autoDictate: Bool {
    get {
      guard defaults.object(forKey: BlurtShared.Key.autoDictate) != nil else { return true }
      return defaults.bool(forKey: BlurtShared.Key.autoDictate)
    }
    set { defaults.set(newValue, forKey: BlurtShared.Key.autoDictate) }
  }

  /// How long a listening window stays open with nobody dictating, in minutes.
  /// 0 means until the user closes it.
  package static var windowMinutes: Int {
    get {
      guard defaults.object(forKey: BlurtShared.Key.windowMinutes) != nil else { return 15 }
      return defaults.integer(forKey: BlurtShared.Key.windowMinutes)
    }
    set { defaults.set(newValue, forKey: BlurtShared.Key.windowMinutes) }
  }

  package static var listeningUntil: Date? {
    get { defaults.object(forKey: BlurtShared.Key.listeningUntil) as? Date }
    set { defaults.set(newValue, forKey: BlurtShared.Key.listeningUntil) }
  }

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
    get { KeyTermList.parse(defaults.string(forKey: keyTermsKey) ?? "") }
    set { defaults.set(KeyTermList.join(newValue), forKey: keyTermsKey) }
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
