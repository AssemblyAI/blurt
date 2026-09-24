import Foundation
import SwiftUI

// MARK: - The App Group contract

/// What the Blurt app and the Blurt keyboard agree on. They are two processes:
/// the app listens and transcribes (iOS lets no keyboard use the microphone),
/// the keyboard drops the words into the field it is attached to. They talk
/// through the App Group's shared defaults and wake each other with Darwin
/// notifications — a system-wide "something changed" ping that carries no data,
/// so every payload lives in the defaults under one of the keys below.
enum BlurtShared {
  /// The App Group both targets declare. A placeholder namespace inherited from
  /// the Mac app; an org-owned id replaces it before the App Store, and the app
  /// and the keyboard must change together.
  static let appGroup = "group.dev.alex.blurt"
  /// The URL the keyboard opens to bring the app forward (`blurt://start`) —
  /// the one moment iOS insists on before the microphone may open.
  static let urlScheme = "blurt"
  static let startHost = "start"

  enum Key {
    static let layout = "keyboardLayout"
    static let listeningUntil = "listeningUntil"
    static let windowMinutes = "listeningWindowMinutes"
    static let phase = "phase"
    static let command = "command"
    static let result = "result"
    static let keyboardSeenAt = "keyboardSeenAt"
    static let keyboardEverSeen = "keyboardEverSeen"
    static let lexicon = "lexicon"
  }

  /// Darwin notification names. Reverse-DNS so they can't collide with another
  /// app's on the same device.
  enum Signal {
    static let command = "dev.alex.blurt.ios.command"
    static let phase = "dev.alex.blurt.ios.phase"
    static let result = "dev.alex.blurt.ios.result"
    static let lexicon = "dev.alex.blurt.ios.lexicon"
  }
}

/// Which keyboard the user chose. All three share the same plumbing underneath;
/// they differ only in how much keyboard sits around the mic.
enum KeyboardLayout: String, CaseIterable, Codable, Sendable, Identifiable {
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
    case .panel: "A big mic with status and cancel. Switch keyboards to type."
    case .full: "Every letter key, with the mic as the main key."
    }
  }

  /// The keyboard's height in points. Fixed per layout; the system keyboard is
  /// about 216 on a phone, which is what `panel` matches.
  var height: CGFloat {
    switch self {
    case .slimBar: 72
    case .panel: 216
    case .full: 264
    }
  }
}

// MARK: - Payloads

/// What the keyboard asks the app to do, with the context only the keyboard can
/// see: the text before the cursor primes the transcript exactly as the Mac's
/// Accessibility read does.
struct KeyboardCommand: Codable, Sendable {
  enum Kind: String, Codable, Sendable {
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
struct DictationResult: Codable, Sendable {
  let id: UUID
  let text: String
  let deliveredAt: Date
}

/// What the keyboard shows while the app works: the pipeline's phase, flattened
/// to what a pill can render, plus the live microphone level.
struct PhaseSnapshot: Codable, Sendable, Equatable {
  enum State: String, Codable, Sendable {
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
}

/// One entry of the phone's own word list (`UILexicon`): contact names and the
/// user's text replacements. Names go to the request as key terms so they come
/// back spelled right; replacements are the phone's own text shortcuts.
struct LexiconEntry: Codable, Sendable, Hashable {
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
  private static var defaults: UserDefaults {
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

  static var layout: KeyboardLayout {
    get { KeyboardLayout(rawValue: defaults.string(forKey: BlurtShared.Key.layout) ?? "") ?? .panel }
    set { defaults.set(newValue.rawValue, forKey: BlurtShared.Key.layout) }
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

  /// Whether the app currently has the microphone open for the keyboard.
  static var isListening: Bool { (listeningUntil ?? .distantPast) > Date() }

  static var keyboardSeenAt: Date? {
    get { defaults.object(forKey: BlurtShared.Key.keyboardSeenAt) as? Date }
    set { defaults.set(newValue, forKey: BlurtShared.Key.keyboardSeenAt) }
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

/// The Mac app's palette (`App/Blurt/Blurt/Branding/BlurtBrand.swift`), for the
/// two iOS targets. Values, not assets, so the keyboard needs no catalog.
enum BlurtBrand {
  static let green = Color(red: 1 / 255, green: 118 / 255, blue: 47 / 255)
  static let greenOnDark = Color(red: 103 / 255, green: 173 / 255, blue: 130 / 255)
  static let ink = Color(red: 29 / 255, green: 27 / 255, blue: 22 / 255)
  static let errorOrange = Color(red: 230 / 255, green: 127 / 255, blue: 54 / 255)
}
