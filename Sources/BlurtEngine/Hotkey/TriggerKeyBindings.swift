import Foundation

/// What a press of one trigger key does (`TriggerKeyBindings.action(for:)`).
public enum TriggerKeyAction: Sendable, Hashable {
  case off
  /// Dictates, with the style the key's choice names.
  case dictate
  /// Reads the selected text aloud (`SelectionSpeechRouting`).
  case readAloud
  /// Records a spoken request about the selected text and reads the answer aloud.
  case ask
}

/// What one trigger key is set to in the Keys tab. Persisted as a string
/// (`raw`, `init(raw:)`) in `TriggerKeyStyleStore`'s map; everywhere else it's
/// this type, so a choice is matched by the compiler rather than by string.
public enum TriggerKeyChoice: Hashable, Sendable {
  case off
  /// Dictates with `style`: a profile's `uuidString`,
  /// `StyleProfileStore.defaultStyleID` for base styling, or
  /// `mainWindowStyle` for whatever the main window has selected.
  case dictate(style: String)
  case readAloud
  case ask

  /// The style id for "use the main window's selection". Not a UUID, and not
  /// `StyleProfileStore.defaultStyleID`, so it can collide with neither.
  public static let mainWindowStyle = "current"
  /// Dictating with the main window's selection: the bound key's default.
  public static let dictate = TriggerKeyChoice.dictate(style: mainWindowStyle)

  public var action: TriggerKeyAction {
    switch self {
    case .off: .off
    case .dictate: .dictate
    case .readAloud: .readAloud
    case .ask: .ask
    }
  }

  /// The stored form. Any string that isn't one of the action markers is a
  /// style id — the encoding from before read and ask existed.
  init(raw: String) {
    switch raw {
    case "": self = .off
    case "read-aloud": self = .readAloud
    case "ask": self = .ask
    default: self = .dictate(style: raw)
    }
  }

  var raw: String {
    switch self {
    case .off: ""
    case .dictate(let style): style
    case .readAloud: "read-aloud"
    case .ask: "ask"
    }
  }
}

/// One read of everything the trigger keys are set to: the bound key
/// (`TriggerKeyStore`), each key's choice (`TriggerKeyStyleStore`) and each
/// key's tap/hold mode (`TriggerKeyActivationStore`, with
/// `TriggerActivationStore` as the mode of a key that has none). Every reader —
/// the tap, the read-aloud router, the press's style, and each view — asks
/// this, so the rules are written once: the bound key always dictates; with no
/// entry, the bound key dictates with the main window's style, left ⌥ reads
/// aloud, and every other key is off; a key with no mode of its own reads
/// aloud on a tap or hold, or else follows the shared mode.
public struct TriggerKeyBindings: Sendable, Equatable {
  /// The key the ready screen and menu bar name, which always dictates.
  public let bound: TriggerKey
  private let choices: [TriggerKey: TriggerKeyChoice]
  private let modes: [TriggerKey: TriggerActivation]
  private let sharedMode: TriggerActivation

  public init(defaults: UserDefaults = .standard) {
    self.init(
      boundKeyCode: defaults.integer(forKey: TriggerKeyStore.defaultsKey),
      choicesRaw: defaults.string(forKey: TriggerKeyStyleStore.defaultsKey) ?? "",
      modesRaw: defaults.string(forKey: TriggerKeyActivationStore.defaultsKey) ?? "",
      sharedModeRaw: defaults.string(forKey: TriggerActivationStore.defaultsKey) ?? "")
  }

  /// From the raw slots a view has already observed through `@AppStorage`.
  public init(boundKeyCode: Int, choicesRaw: String, modesRaw: String, sharedModeRaw: String) {
    bound = TriggerKey.fromPersisted(boundKeyCode)
    choices = TriggerKeyMap.decode(choicesRaw).mapValues(TriggerKeyChoice.init(raw:))
    modes = TriggerKeyMap.decode(modesRaw).compactMapValues(TriggerActivation.init(rawValue:))
    sharedMode = TriggerActivation.fromPersisted(sharedModeRaw)
  }

  /// What `key` does with no choice of its own. Left ⌥ rather than left ⌘
  /// reads aloud: ⌘ is down for every shortcut and ⌘-click, so a lone press of
  /// it is far more often the start of something else.
  public static func defaultChoice(for key: TriggerKey, bound: TriggerKey) -> TriggerKeyChoice {
    if key == bound { return .dictate }
    return key == .leftOption ? .readAloud : .off
  }

  /// `key`'s choice. The bound key always dictates, whatever its entry says.
  public func choice(for key: TriggerKey) -> TriggerKeyChoice {
    let choice = choices[key] ?? Self.defaultChoice(for: key, bound: bound)
    return key == bound && choice.action != .dictate ? .dictate : choice
  }

  /// `key`'s choice as its pop-up shows it: a style since deleted shows as the
  /// main window's, which is what a press of that key then dictates with (see
  /// `StyleProfileStore.profile(for:)`).
  public func choice(for key: TriggerKey, profiles: [StyleProfile]) -> TriggerKeyChoice {
    guard case .dictate(let style) = choice(for: key), !StyleProfileStore.isStyle(style, in: profiles) else {
      return choice(for: key)
    }
    return .dictate
  }

  /// What a press of `key` does.
  public func action(for key: TriggerKey) -> TriggerKeyAction { choice(for: key).action }

  /// `key`'s tap/hold mode.
  public func activation(for key: TriggerKey) -> TriggerActivation {
    if let mode = modes[key] { return mode }
    return key != bound && action(for: key) == .readAloud ? .tapOrHold : sharedMode
  }

  /// The keys the tap watches: every key that does something.
  public var enabledKeys: Set<TriggerKey> { Set(TriggerKey.allCases.filter { action(for: $0) != .off }) }

  /// The keys that dictate, in `TriggerKey` order — the bound key among them.
  public var dictatingKeys: [TriggerKey] { TriggerKey.allCases.filter { action(for: $0) == .dictate } }

  /// Whether `key` is the only key that dictates, so it can't be set to
  /// anything else (`TriggerKeyStyleStore.setChoice` refuses it).
  public func isOnlyDictatingKey(_ key: TriggerKey) -> Bool { dictatingKeys == [key] }

  /// The keys besides the bound one that do something, in `TriggerKey` order:
  /// the ready screen's extra rows.
  public var extraKeys: [TriggerKey] {
    TriggerKey.allCases.filter { $0 != bound && action(for: $0) != .off }
  }

  /// Whether some key reads aloud or asks — read-aloud's settings do something
  /// — and whether some key asks, which sends what's said to the LLM Gateway.
  public var readsOrAsks: Bool { TriggerKey.allCases.contains { [.readAloud, .ask].contains(action(for: $0)) } }
  public var asks: Bool { TriggerKey.allCases.contains { action(for: $0) == .ask } }

  /// Every key the tap watches, with its mode — the router's binding.
  public var activations: [TriggerKey: TriggerActivation] {
    Dictionary(uniqueKeysWithValues: enabledKeys.map { ($0, activation(for: $0)) })
  }
}
