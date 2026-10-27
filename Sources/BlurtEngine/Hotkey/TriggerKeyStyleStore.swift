import Foundation

/// Persists which style each trigger key dictates with — and so which keys
/// dictate at all: the bound key (`TriggerKeyStore`) always does, and any other
/// `TriggerKey` does once the user gives it a style in the Shortcut section.
/// Every key is still a lone modifier from the same curated set, watched by the
/// same listen-only tap; this only widens which of them the router matches.
///
/// Stored as one JSON object, keycode → style id, under its own key so an
/// install that never touches it reads exactly as before: no entries, one key,
/// the main window's style. A style id is a profile's `uuidString`,
/// `StyleProfileStore.defaultStyleID` for base styling, or `currentStyleID` for
/// "whatever the main window has selected". A press never writes the main
/// window's selection — see `PressStyle`.
public struct TriggerKeyStyleStore {
  /// Public so SwiftUI views can observe it directly (e.g. `@AppStorage`).
  public static var defaultsKey: String { DefaultsKey.triggerKeyStyles.key }

  /// The style id for "use the main window's selection". Not a UUID, and not
  /// `StyleProfileStore.defaultStyleID`, so it can collide with neither.
  public static let currentStyleID = "current"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Each key's chosen style id; a key with no entry is off, unless it is the
  /// bound key, which dictates with the current style.
  public var styles: [TriggerKey: String] {
    Self.styles(decoding: defaults.string(forKey: Self.defaultsKey) ?? "")
  }

  /// Gives `key` the style `styleID`, or turns it off for `""` — the Shortcut
  /// menu's write, through here because the value is encoded. Returns whether
  /// that changed which keys dictate, the one case the tap has to rebind for:
  /// a style-only change is read at the next press, and a rebind would discard
  /// a recording in progress.
  public func setStyle(_ styleID: String, for key: TriggerKey) -> Bool {
    let wasEnabled = enabledKeys
    var styles = styles
    styles[key] = styleID.isEmpty ? nil : styleID
    let raw = Dictionary(uniqueKeysWithValues: styles.map { (String($0.key.rawValue), $0.value) })
    guard let data = try? JSONEncoder().encode(raw), let json = String(data: data, encoding: .utf8)
    else { return false }
    defaults.set(json, forKey: Self.defaultsKey)
    return enabledKeys != wasEnabled
  }

  /// The mapping behind a raw slot value a view has already observed. Blank or
  /// undecodable reads as no mappings, and an entry for a keycode outside
  /// `TriggerKey` is dropped, so a hand-edited value can't bind a new key.
  public static func styles(decoding raw: String) -> [TriggerKey: String] {
    guard let decoded = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)) else {
      return [:]
    }
    var styles: [TriggerKey: String] = [:]
    for (code, id) in decoded {
      if let key = Int(code).flatMap(TriggerKey.init(rawValue:)) { styles[key] = id }
    }
    return styles
  }

  /// The keys that dictate: the bound key plus every key with a style.
  public var enabledKeys: Set<TriggerKey> {
    Self.enabledKeys(bound: TriggerKeyStore(defaults: defaults).triggerKey, styles: styles)
  }

  /// `enabledKeys` over values a view has already observed.
  public static func enabledKeys(bound: TriggerKey, styles: [TriggerKey: String]) -> Set<TriggerKey> {
    Set(styles.keys).union([bound])
  }

  /// The style a press of `key` asks for, or nil for the main window's
  /// selection — what `PressStyle.request(_:)` takes.
  public func styleID(for key: TriggerKey) -> String? {
    guard let id = styles[key], id != Self.currentStyleID else { return nil }
    return id
  }

  /// What `key`'s Shortcut row shows: `""` (off), `currentStyleID`, or a style
  /// id that still exists. A style since deleted shows as the current style,
  /// which is what a press of that key then dictates with (see
  /// `StyleProfileStore.profile(for:)`).
  public static func choice(
    for key: TriggerKey, bound: TriggerKey, styles: [TriggerKey: String], profiles: [StyleProfile]
  ) -> String {
    guard let id = styles[key] else { return key == bound ? currentStyleID : "" }
    return StyleProfileStore.isStyle(id, in: profiles) ? id : currentStyleID
  }
}
