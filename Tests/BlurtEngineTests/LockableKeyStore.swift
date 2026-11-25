import Synchronization

@testable import BlurtEngine

/// An in-memory key store that reads as empty while "locked", standing in for
/// a Keychain item that can't be read until the login Keychain unlocks.
final class LockableKeyStore: APIKeyGateway {
  let locked = Mutex(false)
  private let inner = InMemoryAPIKeyStore()

  var current: String? { locked.withLock { $0 } ? nil : inner.current }

  @discardableResult
  func save(_ key: String?) -> Bool { inner.save(key) }
}
