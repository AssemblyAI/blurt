import Foundation
import Testing

@testable import BlurtEngine

/// Exercises the service rename against real keychain items under isolated
/// services, so the production `APIKeyStore` item is never touched. Serialized
/// because keychain items are process-global state.
@Suite("MigratingKeychainStore", .serialized)
struct MigratingKeychainStoreTests {

  /// A throwaway pair unique to each test, cleaned up by the `defer`s below.
  /// Both halves share one account, mirroring production: only the service moved.
  private func makeStore() -> MigratingKeychainStore {
    let account = "test-\(UUID().uuidString)"
    return MigratingKeychainStore(
      current: KeychainStore(service: "dev.alex.blurt.tests.current", account: account),
      legacy: KeychainStore(service: "dev.alex.blurt.tests.legacy", account: account))
  }

  @Test("a key saved under the legacy service is adopted, and the old item removed")
  func adoptsLegacyValue() {
    // The whole point of the rename: an existing install must not be silently
    // logged out, and the old-looking entry must not survive in Keychain Access.
    let store = makeStore()
    defer { store.write(nil) }
    #expect(store.legacy.write("sk-legacy"))

    #expect(store.read() == .value("sk-legacy"))
    #expect(store.current.read() == .value("sk-legacy"))
    #expect(store.legacy.read() == .absent)
  }

  @Test("a value under the current service wins and leaves the legacy item alone")
  func currentValueWins() {
    let store = makeStore()
    defer {
      store.write(nil)
      store.legacy.write(nil)
    }
    #expect(store.legacy.write("sk-stale"))
    #expect(store.write("sk-current"))
    // `write` clears the legacy item, so re-plant it to prove the read doesn't
    // consult it once the current item holds a value.
    #expect(store.legacy.write("sk-stale"))

    #expect(store.read() == .value("sk-current"))
  }

  @Test("both services empty reads as absent")
  func absentEverywhere() {
    let store = makeStore()
    defer { store.write(nil) }
    #expect(store.read() == .absent)
  }

  @Test("deleting the key doesn't resurrect the legacy one on the next read")
  func writeClearsLegacy() {
    // Without the legacy delete on write, clearing the key in Settings would put
    // the pre-rename key back at the next read — the user's "disconnect" undone.
    let store = makeStore()
    defer { store.write(nil) }
    #expect(store.legacy.write("sk-legacy"))
    #expect(store.write("sk-current"))

    #expect(store.write(nil))
    #expect(store.read() == .absent)
    #expect(store.legacy.read() == .absent)
  }

  @Test("a round-trip through the current service behaves like a plain store")
  func roundTripsCurrentService() {
    let store = makeStore()
    defer { store.write(nil) }
    #expect(store.write("  sk-trim  \n"))
    #expect(store.read() == .value("sk-trim"))
    #expect(store.write("second"))
    #expect(store.read() == .value("second"))
  }
}
