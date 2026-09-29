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

  /// Where the replaced value is kept: a suite of its own, shared by every build
  /// (`sharedSuite`), not the host's domain. The system setting is one value for
  /// the whole login, so its record must be too — kept per host, Blurt and Blurt
  /// Dev each recorded the other's override as "the original" and could restore
  /// each other to Do Nothing for good. Also why it isn't a `DefaultsKey` case:
  /// `PersistedSettings.resetAll` sweeps those, and a reset that forgot this
  /// would strand the user's setting at "Do Nothing" — the relaunch after a reset
  /// is exactly when it gets restored. `scripts/reset-install.sh` restores from
  /// and deletes this suite, since it wipes the host domains outright.
  static let replacedUsageKey = "hotkey.replacedGlobeKeyUsage"
  static var sharedSuite: String { HostIdentity.current.subsystem + ".globe-key" }
  /// Recorded when the system key was unset, so restoring removes it rather than
  /// pinning whatever macOS's default happened to be.
  static let wasUnset = -1

  private let system: UserDefaults?
  private let record: UserDefaults?

  /// Both default to the real domains (reachable because the app isn't
  /// sandboxed); tests pass throwaway suites. If either can't be opened, `sync`
  /// does nothing rather than write the override somewhere macOS never reads it.
  public init(system: UserDefaults? = nil, record: UserDefaults? = nil) {
    // `init(suiteName:)` refuses only the caller's own bundle id and the global
    // domain, neither of which these are.
    self.system = system ?? UserDefaults(suiteName: Self.systemDomain)
    self.record = record ?? UserDefaults(suiteName: Self.sharedSuite)
  }

  /// A raw write to another app's domain isn't picked up live: macOS reads
  /// `AppleFnUsageType` at login (System Settings applies it through its own
  /// path), so the override lands after the next log-out. The Shortcut footer
  /// says so and links to Keyboard Settings for changing it right away.
  public func sync(boundKey: TriggerKey) {
    guard let system, let record else { return }
    if boundKey == .function {
      if record.object(forKey: Self.replacedUsageKey) == nil {
        let current = system.object(forKey: Self.usageKey) as? Int ?? Self.wasUnset
        record.set(current, forKey: Self.replacedUsageKey)
      }
      system.set(Self.doNothing, forKey: Self.usageKey)
    } else if let replaced = record.object(forKey: Self.replacedUsageKey) as? Int {
      if replaced == Self.wasUnset {
        system.removeObject(forKey: Self.usageKey)
      } else {
        system.set(replaced, forKey: Self.usageKey)
      }
      record.removeObject(forKey: Self.replacedUsageKey)
    }
  }
}
