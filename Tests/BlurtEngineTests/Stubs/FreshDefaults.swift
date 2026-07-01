import Foundation

/// A throwaway `UserDefaults` suite that never touches the real app domain, for
/// suites exercising the UserDefaults-backed stores (`TriggerKeyStore`,
/// `SoundPackStore`). The UUID keeps parallel tests isolated from each other.
func freshDefaults(_ label: String = #fileID) -> UserDefaults {
  let name = "\(label)-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: name)!
  defaults.removePersistentDomain(forName: name)
  return defaults
}
