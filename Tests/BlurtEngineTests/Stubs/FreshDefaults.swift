import Foundation

@testable import BlurtEngine

/// A throwaway `UserDefaults` suite that never touches the real app domain, for
/// suites exercising the UserDefaults-backed stores (`TriggerKeyStore`,
/// `SoundPackStore`). The UUID keeps parallel tests isolated from each other.
func freshDefaults(_ label: String = #fileID) -> UserDefaults {
  let name = "\(label)-\(UUID().uuidString)"
  guard let defaults = UserDefaults(suiteName: name) else {
    // `init(suiteName:)` refuses only the app's bundle id and the global
    // domain; a UUID-suffixed name can be neither.
    preconditionFailure("could not create UserDefaults suite \(name)")
  }
  defaults.removePersistentDomain(forName: name)
  return defaults
}

/// A `DeveloperModeStore` over an isolated suite with the switch pre-set.
///
/// Seeds the raw defaults slot — exactly what the Settings toggle's `@AppStorage`
/// writes in production — because the store itself is read-only. Centralised here
/// so the log suites don't each restate the key, and so they drive the switch the
/// same way the app does.
func developerModeStore(
  enabled: Bool, defaults: UserDefaults = freshDefaults()
) -> DeveloperModeStore {
  defaults.set(enabled, forKey: DeveloperModeStore.defaultsKey)
  return DeveloperModeStore(defaults: defaults)
}
