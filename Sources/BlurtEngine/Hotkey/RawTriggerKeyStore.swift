import Foundation

/// Persists the **raw** dictation `TriggerKey` as its keycode in `UserDefaults`.
/// The companion to `TriggerKeyStore` (which holds the *cleaned* key): the two
/// stores back the two lone-modifier triggers (`DictationTriggerPair`), one
/// pasting the verbatim transcript and one the server-side cleanup rewrite.
///
/// Defaults to right ⌥ when unset or when the stored code isn't one of the
/// curated options. That default differs from `TriggerKeyStore`'s right ⌘, so
/// the two triggers start out distinct; unlike `TriggerKeyStore` it can't lean
/// on `TriggerKey.fromPersisted` (whose fallback is right ⌘), so the read
/// applies the right-⌥ fallback here — leaving `fromPersisted`'s existing
/// right-⌘ default untouched for the cleaned store and the `@AppStorage` views.
public struct RawTriggerKeyStore {
  /// UserDefaults key holding the raw trigger keycode. Public so SwiftUI views
  /// can observe it directly (e.g. `@AppStorage`) and re-render on change.
  public static let defaultsKey = "BlurtRawTriggerKeyCode"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var triggerKey: TriggerKey {
    get {
      // Unset reads as 0 (not a curated keycode); an unknown code likewise
      // isn't curated. Both fall back to right ⌥ — the raw trigger's default,
      // distinct from the cleaned trigger's right ⌘.
      let code = defaults.integer(forKey: Self.defaultsKey)
      return TriggerKey(rawValue: code) ?? .rightOption
    }
    nonmutating set {
      defaults.set(newValue.rawValue, forKey: Self.defaultsKey)
    }
  }
}
