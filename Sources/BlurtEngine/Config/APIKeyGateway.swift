/// The narrow key-storage seam hosts compose against: read, write, and "is one
/// saved?". `APIKeyStore` is deliberately static (one production Keychain item),
/// so this protocol is how a host injects a different backing — most usefully
/// `InMemoryAPIKeyStore` below, which keeps automated runs away from the real
/// Keychain item (writing it would prompt for Keychain access and corrupt the
/// production key's ACL).
public protocol APIKeyGateway: Sendable {
  /// The stored key, or `nil` if none has been saved (or it's empty).
  var current: String? { get }
  /// Stores `key` (trimmed). Passing `nil` or an empty/whitespace string
  /// deletes the stored key. Returns `true` on success.
  @discardableResult
  func save(_ key: String?) -> Bool
}

extension APIKeyGateway {
  /// Whether a non-empty key is currently stored. Derived from `current` so every
  /// conformance shares the one definition of "has a key".
  public var hasKey: Bool { current != nil }
}
