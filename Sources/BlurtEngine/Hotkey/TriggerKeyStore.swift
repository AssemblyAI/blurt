import Foundation

/// Persists the chosen dictation `TriggerKey` as its keycode in `UserDefaults`.
/// Defaults to right ⌘ when unset or when the stored code isn't one of the
/// curated options.
public struct TriggerKeyStore {
  /// UserDefaults key holding the trigger keycode. Public so SwiftUI views can
  /// observe it directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.triggerKeyCode.key }
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var triggerKey: TriggerKey {
    get {
      // Unset reads as 0, which isn't a curated keycode, so `fromPersisted`'s
      // right-⌘ fallback covers both "never set" and "unknown code".
      TriggerKey.fromPersisted(defaults.integer(forKey: Self.defaultsKey))
    }
    nonmutating set {
      defaults.set(newValue.rawValue, forKey: Self.defaultsKey)
    }
  }

  /// Marks that `migrateStaleFunctionBinding()` has run. Outside `DefaultsKey` on
  /// purpose, like `SigningIdentityMigration.lastSigningIdentityDefaultsKey`: it
  /// records what a migration already did, and a settings reset forgetting it
  /// would turn the user's next deliberate `fn` pick back into right ⌘.
  static let staleFunctionMigrationKey = "hotkey.staleFunctionBindingMigrated"

  /// Rewrites an `fn` binding saved before `fn` was removed (#146) to right ⌘.
  ///
  /// Since that removal the saved keycode 63 has decoded to right ⌘ — what the
  /// user has been pressing, and what the UI has shown. Restoring `fn` would
  /// otherwise flip them back to it on upgrade, with no visible change, and have
  /// `GlobeKeyOverride` switch their 🌐 key off. Runs once, before anything reads
  /// the binding: any 63 written after it is a deliberate choice.
  public func migrateStaleFunctionBinding() {
    guard !defaults.bool(forKey: Self.staleFunctionMigrationKey) else { return }
    if defaults.integer(forKey: Self.defaultsKey) == TriggerKey.function.rawValue {
      triggerKey = .rightCommand
    }
    defaults.set(true, forKey: Self.staleFunctionMigrationKey)
  }
}
