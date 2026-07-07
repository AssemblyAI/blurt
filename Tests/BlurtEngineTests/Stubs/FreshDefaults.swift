import Foundation

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
