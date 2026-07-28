import Foundation

/// Persists when an update check last completed, so the automatic launch check
/// can be throttled to `AutomaticUpdateCheck.minimumInterval` instead of
/// fetching GitHub on every launch. Same shape as `TriggerKeyStore` /
/// `OverlayOriginStore`, and registered in `PersistedSettings.allDefaultsKeys`
/// so every "reset to a clean state" sweep clears it too.
public struct LastUpdateCheckStore {
  /// Public so the reset sweep can name it.
  public static let defaultsKey = "BlurtLastUpdateCheck"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// When a check last produced a result, or `nil` if none ever has.
  ///
  /// Probed with `object(forKey:)` first because `double(forKey:)` reports 0 for
  /// a missing key — i.e. the reference date, a check made two decades ago.
  /// That happens to lead to the same decision as "never checked", but only by
  /// luck, and only while the interval is shorter than the value's age; keeping
  /// "never" its own answer means the gate can't quietly depend on that.
  public var lastCheck: Date? {
    get {
      guard defaults.object(forKey: Self.defaultsKey) != nil else { return nil }
      return Date(timeIntervalSinceReferenceDate: defaults.double(forKey: Self.defaultsKey))
    }
    nonmutating set {
      guard let newValue else {
        defaults.removeObject(forKey: Self.defaultsKey)
        return
      }
      defaults.set(newValue.timeIntervalSinceReferenceDate, forKey: Self.defaultsKey)
    }
  }
}
