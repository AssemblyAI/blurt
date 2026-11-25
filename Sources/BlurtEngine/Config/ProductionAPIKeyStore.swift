/// The production `APIKeyGateway`: a thin, stateless forwarder to the
/// Keychain-backed `APIKeyStore`, so the live app reads/writes the Keychain
/// exactly as the static API does.
public struct ProductionAPIKeyStore: APIKeyGateway {
  public var current: String? { APIKeyStore.current }

  public init() {
    // Stateless: every read and write goes straight to `APIKeyStore`.
  }

  @discardableResult
  public func save(_ key: String?) -> Bool { APIKeyStore.save(key) }
}
