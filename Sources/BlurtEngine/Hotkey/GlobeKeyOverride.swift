import Foundation

/// Keeps macOS's own `fn`/🌐 action out of the way while `fn` is the dictation
/// trigger.
///
/// macOS binds the key itself (System Settings → Keyboard → "Press 🌐 key to":
/// show emoji, change input source, or start Apple Dictation), and the hotkey tap
/// is listen-only, so it can't swallow the press — every dictation would also fire
/// that action, alert sound included. So while `fn` is bound this sets the system
/// setting to "Do Nothing", remembering what it replaced; binding any other key
/// puts that back.
///
/// `sync(boundKey:)` is idempotent and re-applies the override on every call, so
/// a launch with `fn` bound re-asserts it even if the setting was changed in
/// System Settings meanwhile.
public struct GlobeKeyOverride {
  /// The system preference domain and key behind "Press 🌐 key to".
  static let systemDomain = "com.apple.HIToolbox"
  static let usageKey = "AppleFnUsageType"
  /// `AppleFnUsageType`'s "Do Nothing".
  static let doNothing = 0

  /// Where the replaced value is kept, in the host's own domain. Deliberately not
  /// a `DefaultsKey` case: `PersistedSettings.resetAll` sweeps those, and a reset
  /// that forgot this would strand the user's setting at "Do Nothing" — the
  /// relaunch after a reset is exactly when it gets restored.
  static let replacedUsageKey = "hotkey.replacedGlobeKeyUsage"
  /// Recorded when the system key was unset, so restoring removes it rather than
  /// pinning whatever macOS's default happened to be.
  static let wasUnset = -1

  private let system: UserDefaults
  private let own: UserDefaults

  /// `system` defaults to the real `com.apple.HIToolbox` domain (reachable because
  /// the app isn't sandboxed); tests pass throwaway suites for both.
  public init(system: UserDefaults? = nil, own: UserDefaults = .standard) {
    // `init(suiteName:)` refuses only the caller's own bundle id and the global
    // domain, neither of which this is.
    self.system = system ?? UserDefaults(suiteName: Self.systemDomain) ?? .standard
    self.own = own
  }

  public func sync(boundKey: TriggerKey) {
    if boundKey == .function {
      if own.object(forKey: Self.replacedUsageKey) == nil {
        let current = system.object(forKey: Self.usageKey) as? Int ?? Self.wasUnset
        own.set(current, forKey: Self.replacedUsageKey)
      }
      system.set(Self.doNothing, forKey: Self.usageKey)
    } else if let replaced = own.object(forKey: Self.replacedUsageKey) as? Int {
      if replaced == Self.wasUnset {
        system.removeObject(forKey: Self.usageKey)
      } else {
        system.set(replaced, forKey: Self.usageKey)
      }
      own.removeObject(forKey: Self.replacedUsageKey)
    }
  }
}
