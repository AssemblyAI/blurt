public import Foundation

/// One read of everything the trigger keys are set to: the bound key
/// (`TriggerKeyStore`), each key's choice (`TriggerKeyStyleStore`) and the one
/// tap/hold mode they're all pressed under (`TriggerActivationStore`). Every
/// reader — the tap, the read-aloud router, the press's style, and each view —
/// asks this, so the rules are written once: with no entry, the bound key
/// dictates with the main window's style, left ⌥ reads aloud, and every other
/// key is off. Any key can be set to None, the last dictating one included;
/// when some key still dictates, the bound key is one of them
/// (`TriggerKeyStyleStore.setChoice` keeps that).
public struct TriggerKeyBindings: Sendable, Equatable {
  /// The key the ready screen and menu bar name — when it dictates
  /// (`dictationKey`). Kept on a dictating key while there is one.
  public let bound: TriggerKey
  private let choices: [TriggerKey: TriggerKeyChoice]
  /// How every key is pressed.
  public let activation: TriggerActivation

  /// The dictation key the ready screen and menu bar name: the bound key, or
  /// nil when no key dictates.
  public var dictationKey: TriggerKey? { action(for: bound) == .dictate ? bound : nil }

  /// The keys the tap watches: every key that does something.
  public var enabledKeys: Set<TriggerKey> { Set(TriggerKey.allCases.filter { action(for: $0) != .off }) }

  /// The keys that dictate, in `TriggerKey` order — the bound key among them,
  /// unless there are none.
  public var dictatingKeys: [TriggerKey] { TriggerKey.allCases.filter { action(for: $0) == .dictate } }

  /// The keys besides the dictation key that do something, in `TriggerKey`
  /// order: the ready screen's extra rows. With nothing dictating, the bound
  /// key is among them if it does something else.
  public var extraKeys: [TriggerKey] {
    TriggerKey.allCases.filter { $0 != dictationKey && action(for: $0) != .off }
  }

  /// Whether some key reads aloud or asks — read-aloud's settings do something.
  public var readsOrAsks: Bool { TriggerKey.allCases.contains { [.readAloud, .ask].contains(action(for: $0)) } }

  /// Every key the tap watches, with the mode — the router's binding.
  public var activations: [TriggerKey: TriggerActivation] {
    Dictionary(uniqueKeysWithValues: enabledKeys.map { ($0, activation) })
  }

  public init(defaults: UserDefaults = .standard) {
    self.init(
      boundKeyCode: defaults.integer(forKey: TriggerKeyStore.defaultsKey),
      choicesRaw: defaults.string(forKey: TriggerKeyStyleStore.defaultsKey) ?? "",
      activationRaw: defaults.string(forKey: TriggerActivationStore.defaultsKey) ?? ""
    )
  }

  /// From the raw slots a view has already observed through `@AppStorage`.
  public init(boundKeyCode: Int, choicesRaw: String, activationRaw: String) {
    bound = TriggerKey.fromPersisted(boundKeyCode)
    choices = TriggerKeyMap.decode(choicesRaw).mapValues(TriggerKeyChoice.init(raw:))
    activation = TriggerActivation.fromPersisted(activationRaw)
  }

  /// What `key` does with no choice of its own. Left ⌥ rather than left ⌘
  /// reads aloud: ⌘ is down for every shortcut and ⌘-click, so a lone press of
  /// it is far more often the start of something else.
  public static func defaultChoice(for key: TriggerKey, bound: TriggerKey) -> TriggerKeyChoice {
    if key == bound {
      return .dictate
    }
    return key == .leftOption ? .readAloud : .off
  }

  /// `key`'s choice: its entry, else its default.
  public func choice(for key: TriggerKey) -> TriggerKeyChoice {
    choices[key] ?? Self.defaultChoice(for: key, bound: bound)
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
}
