import Synchronization

/// The narrow key-storage seam hosts compose against: read, write, and "is one
/// saved?". `APIKeyStore` is deliberately static (one production Keychain item),
/// so this protocol is how a host injects a different backing — most usefully
/// `InMemoryAPIKeyStore` below, which keeps automated runs away from the real
/// Keychain item (writing it would prompt for Keychain access and corrupt the
/// production key's ACL).
public protocol APIKeyGateway: Sendable {
  /// The stored key, or `nil` if none has been saved (or it's empty).
  func get() -> String?
  /// Stores `key` (trimmed). Passing `nil` or an empty/whitespace string
  /// deletes the stored key. Returns `true` on success.
  @discardableResult func set(_ key: String?) -> Bool
}

extension APIKeyGateway {
  /// Whether a non-empty key is currently stored. Derived from `get()` so every
  /// conformance shares the one definition of "has a key".
  public var hasKey: Bool { get() != nil }
}

/// The production `APIKeyGateway`: a thin, stateless forwarder to the
/// Keychain-backed `APIKeyStore`, so the live app reads/writes the Keychain
/// exactly as the static API does.
public struct ProductionAPIKeyStore: APIKeyGateway {
  public init() {}
  public func get() -> String? { APIKeyStore.get() }
  @discardableResult public func set(_ key: String?) -> Bool { APIKeyStore.set(key) }
}

/// In-memory `APIKeyGateway` for tests and harnesses (Blurt's XCUITest runs use
/// it so the real Keychain item is never touched). Backed by a `Mutex`, which is
/// itself `Sendable` — so the type is safely `Sendable` without an `@unchecked`
/// escape hatch.
public final class InMemoryAPIKeyStore: APIKeyGateway {
  private let key = Mutex<String?>(nil)

  public init() {}

  public func get() -> String? {
    key.withLock { $0 }
  }

  @discardableResult
  public func set(_ newKey: String?) -> Bool {
    key.withLock { $0 = newKey.trimmedNonEmpty() }
    return true
  }
}
