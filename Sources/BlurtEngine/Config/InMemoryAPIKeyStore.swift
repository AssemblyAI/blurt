import Synchronization

/// In-memory `APIKeyGateway` for tests and harnesses (Blurt's XCUITest runs use
/// it so the real Keychain item is never touched). Backed by a `Mutex`, which is
/// itself `Sendable` — so the type is safely `Sendable` without an `@unchecked`
/// escape hatch.
public final class InMemoryAPIKeyStore: APIKeyGateway {
  private let key = Mutex<String?>(nil)

  public var current: String? {
    key.withLock { $0 }
  }

  public init() {
    // Starts with no key, like a fresh install's Keychain.
  }

  @discardableResult
  public func save(_ newKey: String?) -> Bool {
    key.withLock { $0 = newKey.trimmedNonEmpty() }
    return true
  }
}
