#if UITEST_HOOKS

  import AssemblyAI
  import BlurtEngine

  // The real Keychain stays untouched under UI testing via the engine's
  // `InMemoryAPIKeyStore` (`Sources/BlurtEngine/Config/APIKeyGateway.swift`),
  // injected as the coordinator's key store in `AppDelegate`.

  /// Offline API-key validation for UI testing, injected as the coordinator's
  /// `validateKey` in place of AssemblyAI's network check: the sentinel keys map
  /// to fixed outcomes (so the settings inline-error paths are reachable) and any
  /// other key validates. `APIKeySubmission` still owns the save-on-`.valid`
  /// rule, so this drives the whole real submit flow — no special-case branch in
  /// the coordinator.
  enum UITestKeyValidation {
    // nonisolated: called from the coordinator's nonisolated @Sendable
    // `validateKey` closure, not the main actor (the app's default isolation).
    nonisolated static func result(for key: String) -> APIKeyValidator.Result {
      switch key {
      case UITestIdentifiers.invalidAPIKey:
        return .invalid

      case UITestIdentifiers.unreachableAPIKey:
        return .unreachable

      default:
        return .valid
      }
    }
  }

#endif
