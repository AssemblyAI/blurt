import Foundation
import Testing

@testable import BlurtEngine

/// Round-trips `KeychainStore` against an isolated service/account so the real
/// `APIKeyStore` item is never touched. Serialized because keychain items are
/// process-global state.
@Suite("KeychainStore", .serialized)
struct KeychainStoreTests {

  /// A throwaway store unique to each test run, cleaned up by `set(nil)`.
  private func makeStore() -> KeychainStore {
    KeychainStore(service: "dev.alex.blurt.tests", account: "test-\(UUID().uuidString)")
  }

  @Test("get returns nil before anything is stored")
  func getEmpty() {
    let store = makeStore()
    defer { store.write(nil) }
    #expect(store.read() == .absent)
  }

  @Test("set then read round-trips the value")
  func setThenGet() {
    let store = makeStore()
    defer { store.write(nil) }
    #expect(store.write("sk-abc123"))
    #expect(store.read() == .value("sk-abc123"))
  }

  @Test("read distinguishes an absent item from a stored value")
  func readReportsAbsentVsValue() {
    // Why this distinction exists: `APIKeyStore` memoizes the read, and collapsing
    // "nothing saved" and "couldn't read it" to a bare nil let a transient failure
    // (locked keychain, denied ACL prompt) get cached as a permanent "no API key"
    // for the whole process. `.unavailable` can't be provoked here — it needs a
    // locked keychain or a denied prompt — so this pins the two reachable arms.
    let store = makeStore()
    defer { store.write(nil) }

    #expect(store.read() == .absent)
    #expect(store.write("sk-abc123"))
    #expect(store.read() == .value("sk-abc123"))
    #expect(store.write(nil))
    #expect(store.read() == .absent)
  }

  @Test("set overwrites an existing value (update path)")
  func overwrite() {
    let store = makeStore()
    defer { store.write(nil) }
    #expect(store.write("first"))
    #expect(store.write("second"))
    #expect(store.read() == .value("second"))
  }

  @Test("set trims surrounding whitespace")
  func trimsWhitespace() {
    let store = makeStore()
    defer { store.write(nil) }
    #expect(store.write("  sk-trim  \n"))
    #expect(store.read() == .value("sk-trim"))
  }

  @Test("set(nil) deletes the stored value")
  func deleteWithNil() {
    let store = makeStore()
    defer { store.write(nil) }
    #expect(store.write("to-be-deleted"))
    #expect(store.write(nil))
    #expect(store.read() == .absent)
  }

  @Test("set(whitespace) deletes, get returns nil")
  func deleteWithBlank() {
    let store = makeStore()
    defer { store.write(nil) }
    #expect(store.write("present"))
    #expect(store.write("   "))
    #expect(store.read() == .absent)
  }
}
