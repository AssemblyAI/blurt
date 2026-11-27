import Foundation

/// A throwaway `UserDefaults` suite that never touches the app's own domain —
/// the engine tests' `freshDefaults()`, for what the coordinator keeps in the
/// process's defaults (consent, the session switch, the stats). The UUID keeps
/// tests running side by side apart.
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
