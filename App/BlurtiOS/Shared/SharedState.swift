import Foundation

// MARK: - The App Group contract

/// What the Blurt app and the Blurt keyboard agree on. They are two processes:
/// the app listens and transcribes (iOS lets no keyboard use the microphone),
/// the keyboard drops the words into the field it is attached to. They talk
/// through the App Group's shared defaults and wake each other with Darwin
/// notifications — a system-wide "something changed" ping that carries no data,
/// so every payload lives in the defaults under one of the keys below.
nonisolated enum BlurtShared {
  /// The App Group both targets declare. A placeholder namespace inherited from
  /// the Mac app; an org-owned id replaces it before the App Store, and the app
  /// and the keyboard must change together.
  static let appGroup = "group.dev.alex.blurt"
  /// The URL the keyboard opens to bring the app forward (`blurt://start`) —
  /// the one moment iOS insists on before the microphone may open.
  static let urlScheme = "blurt"
  static let startHost = "start"

  nonisolated enum Key {
    static let layout = "keyboardLayout"
    static let autoDictate = "autoDictate"
    static let listeningUntil = "listeningUntil"
    static let windowMinutes = "listeningWindowMinutes"
    static let phase = "phase"
    static let command = "command"
    static let result = "result"
    static let keyboardSeenAt = "keyboardSeenAt"
    static let appSeenAt = "appSeenAt"
    static let keyboardEverSeen = "keyboardEverSeen"
    static let lexicon = "lexicon"
    static let lexiconRefreshedAt = "lexiconRefreshedAt"
  }

  /// Darwin notification names. Reverse-DNS so they can't collide with another
  /// app's on the same device.
  nonisolated enum Signal {
    static let command = "dev.alex.blurt.ios.command"
    static let phase = "dev.alex.blurt.ios.phase"
    static let result = "dev.alex.blurt.ios.result"
    static let lexicon = "dev.alex.blurt.ios.lexicon"
  }
}

/// Which keyboard the user chose. All three share the same plumbing underneath;
/// they differ only in how much keyboard sits around the mic.
nonisolated enum KeyboardLayout: String, CaseIterable, Codable, Sendable, Identifiable {
  /// A slim strip: the mic, delete, return and the globe. Typing letters means
  /// switching back to the system keyboard.
  case slimBar
  /// A mic panel with the status pill, a cancel button and a few keys — the
  /// shape Wispr and Aqua ship.
  case panel
  /// A complete keyboard with the mic as the main key, so nobody has to switch
  /// keyboards to fix a typo.
  case full

  var id: String { rawValue }

  var title: String {
    switch self {
    case .slimBar: "Mic bar"
    case .panel: "Mic panel"
    case .full: "Full keyboard"
    }
  }

  var summary: String {
    switch self {
    case .slimBar: "Just the mic and a few keys. Switch keyboards to type."
    case .panel: "A big mic with status and cancel. Swipe sideways for the full keyboard, and back."
    case .full: "Every letter key, with the orb above them."
    }
  }

  /// The keyboard's height in points. Fixed per layout; the system keyboard is
  /// about 216 on a phone, which is what `panel` matches.
  /// The keyboard's height on screen, from the layout's rows at the iPhone
  /// keyboard's own spacing: see `App/BlurtiOS/DESIGN.md` for the arithmetic.
  var height: CGFloat {
    switch self {
    case .slimBar: 60
    case .panel: 216
    case .full: 272
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
nonisolated struct KeyboardCommand: Codable, Sendable {
  nonisolated enum Kind: String, Codable, Sendable {
    case press
    case release
    case cancel
  }

  let id: UUID
  let kind: Kind
  let priorText: String?
  let selectedText: String?
  let sentAt: Date
}

/// The words the app got back, for the keyboard to insert. The keyboard joins
/// them onto the live text before the cursor itself (`InsertionSeparator`),
/// since the user may have typed since the press.
nonisolated struct DictationResult: Codable, Sendable {
  let id: UUID
  let text: String
  let deliveredAt: Date
}

/// What the keyboard shows while the app works: the pipeline's phase, flattened
/// to what a pill can render, plus the live microphone level.
nonisolated struct PhaseSnapshot: Codable, Sendable, Equatable {
  nonisolated enum State: String, Codable, Sendable {
    case idle
    case connecting
    case recording
    case processing
    case pasted
    case copied
    case error
  }

  let state: State
  let message: String?
  let level: Double
  let at: Date

  static let idle = PhaseSnapshot(state: .idle, message: nil, level: 0, at: .distantPast)

  /// How long a notice stays on the pill before it settles back to idle — the
  /// Mac's 0.8 s / 1.6 s dwell, a little longer since a phone has no hover to
  /// reveal more. Nil for the states that end on their own.
  var noticeDwellSeconds: Double? {
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
  var isStale: Bool {
    let age = Date().timeIntervalSince(at)
    switch state {
    case .idle: return false
    case .pasted, .copied, .error: return age > 3
    case .connecting, .recording, .processing: return age > 130
    }
  }
}

/// One entry of the phone's own word list (`UILexicon`): contact names and the
/// user's text replacements. Names go to the request as key terms so they come
/// back spelled right; replacements are the phone's own text shortcuts.
nonisolated struct LexiconEntry: Codable, Sendable, Hashable {
  let userInput: String
  let documentText: String

  /// Contact names come through with both fields equal; a text replacement
  /// has a shortcut on one side and its expansion on the other.
  var isName: Bool { userInput == documentText }
}

// MARK: - Shared defaults

/// Typed access to the App Group's defaults, usable from any thread — the
/// keyboard writes from the main actor, the app's capture path reads from
/// wherever the engine calls it.
nonisolated enum SharedStore {
  /// The App Group's defaults — what both processes read and write. Falls
  /// back to the process's own only where the group is out of reach (a
  /// keyboard without Full Access), so nothing crashes; nothing is shared then.
  static var defaults: UserDefaults {
    UserDefaults(suiteName: BlurtShared.appGroup) ?? .standard
  }

  static func write<Value: Encodable>(_ value: Value, forKey key: String) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: key)
  }

  static func read<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  static func remove(forKey key: String) {
    defaults.removeObject(forKey: key)
  }

  static var layout: KeyboardLayout {
    get { KeyboardLayout(rawValue: defaults.string(forKey: BlurtShared.Key.layout) ?? "") ?? .panel }
    set { defaults.set(newValue.rawValue, forKey: BlurtShared.Key.layout) }
  }

  /// Hands-free: the keyboard starts a dictation the moment it appears in a
  /// text field, so there is nothing to tap before talking. On by default.
  static var autoDictate: Bool {
    get {
      guard defaults.object(forKey: BlurtShared.Key.autoDictate) != nil else { return true }
      return defaults.bool(forKey: BlurtShared.Key.autoDictate)
    }
    set { defaults.set(newValue, forKey: BlurtShared.Key.autoDictate) }
  }

  /// How long a listening window stays open with nobody dictating, in minutes.
  /// 0 means until the user closes it.
  static var windowMinutes: Int {
    get {
      guard defaults.object(forKey: BlurtShared.Key.windowMinutes) != nil else { return 15 }
      return defaults.integer(forKey: BlurtShared.Key.windowMinutes)
    }
    set { defaults.set(newValue, forKey: BlurtShared.Key.windowMinutes) }
  }

  static var listeningUntil: Date? {
    get { defaults.object(forKey: BlurtShared.Key.listeningUntil) as? Date }
    set { defaults.set(newValue, forKey: BlurtShared.Key.listeningUntil) }
  }

  /// How recently the app must have checked in to count as alive. Its
  /// heartbeat is every few seconds while the microphone is open.
  static let appPresenceWindow: TimeInterval = 15

  /// Whether the app currently has the microphone open for the keyboard: the
  /// window has not lapsed, and the app is still there to hear — iOS may have
  /// killed it, or a phone call taken the microphone, with the window's end
  /// still in the future. The keyboard then opens the app rather than sending
  /// a press nobody would answer.
  static var isListening: Bool {
    guard (listeningUntil ?? .distantPast) > Date() else { return false }
    return Date().timeIntervalSince(appSeenAt ?? .distantPast) < appPresenceWindow
  }

  // MARK: Key terms

  /// The user's own key terms — names and jargon the request should spell
  /// right — under the engine's own key (`KeyTermsStore.defaultsKey`,
  /// `BlurtKeyTerms`, comma-separated) but in the App Group, so the keyboard
  /// can add one on the spot and the app reads it on the very next press.
  static var keyTerms: [String] {
    get { KeyTermList.parse(defaults.string(forKey: keyTermsKey) ?? "") }
    set { defaults.set(KeyTermList.join(newValue), forKey: keyTermsKey) }
  }

  /// `BlurtKeyTerms` — spelled out here rather than imported from the engine so
  /// the keyboard, which links it too, and the app can't disagree.
  static let keyTermsKey = "BlurtKeyTerms"

  /// Adds a term unless it is already there (case-insensitively). Returns
  /// whether the list changed.
  @discardableResult
  static func addKeyTerm(_ term: String) -> Bool {
    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    var terms = keyTerms
    guard !terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
    terms.append(trimmed)
    keyTerms = terms
    return true
  }

  static var appSeenAt: Date? {
    get { defaults.object(forKey: BlurtShared.Key.appSeenAt) as? Date }
    set { defaults.set(newValue, forKey: BlurtShared.Key.appSeenAt) }
  }

  static var keyboardSeenAt: Date? {
    get { defaults.object(forKey: BlurtShared.Key.keyboardSeenAt) as? Date }
    set { defaults.set(newValue, forKey: BlurtShared.Key.keyboardSeenAt) }
  }

  /// When the keyboard last copied the phone's word list into the App Group.
  static var lexiconRefreshedAt: Date? {
    get { defaults.object(forKey: BlurtShared.Key.lexiconRefreshedAt) as? Date }
    set { defaults.set(newValue, forKey: BlurtShared.Key.lexiconRefreshedAt) }
  }

  /// Set by the keyboard the first time it runs with Full Access — the only
  /// public-API way the app can tell that the keyboard was added and allowed.
  static var keyboardEverSeen: Bool {
    get { defaults.bool(forKey: BlurtShared.Key.keyboardEverSeen) }
    set { defaults.set(newValue, forKey: BlurtShared.Key.keyboardEverSeen) }
  }

  /// Fires a Darwin notification. Carries nothing: the receiver reads the
  /// payload back out of these defaults.
  static func post(_ signal: String) {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(signal as CFString), nil, nil, true)
  }
}

/// A Darwin-notification subscription that lives as long as this object does.
///
/// The handler runs on whichever thread the system delivers on and is
/// `@Sendable` for that reason; hop to the main actor inside it when the work
/// is UI. A class rather than a token so `deinit` can deregister — a listener
/// left behind outlives its owner, since the system holds the callback.
nonisolated final class DarwinObserver: Sendable {
  private let name: String
  private let handler: @Sendable () -> Void

  init(name: String, handler: @escaping @Sendable () -> Void) {
    self.name = name
    self.handler = handler
    let observer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), observer,
      { _, observer, _, _, _ in
        guard let observer else { return }
        Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue().handler()
      }, name as CFString, nil, .deliverImmediately)
  }

  deinit {
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
      CFNotificationName(name as CFString), nil)
  }
}

// MARK: - Brand

/// The comma-separated key-term list, as the engine's `KeyTermsStore` reads
/// it: split, trimmed, emptied of blanks, deduplicated case-insensitively in
/// first-seen order.
nonisolated enum KeyTermList {
  static func parse(_ raw: String) -> [String] {
    var seen = Set<String>()
    var terms: [String] = []
    for piece in raw.split(separator: ",") {
      let term = piece.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
      terms.append(term)
    }
    return terms
  }

  static func join(_ terms: [String]) -> String {
    terms.joined(separator: ", ")
  }
}
