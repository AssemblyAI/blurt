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
    defer { store.set(nil) }
    #expect(store.get() == nil)
  }

  @Test("set then get round-trips the value")
  func setThenGet() {
    let store = makeStore()
    defer { store.set(nil) }
    #expect(store.set("sk-abc123"))
    #expect(store.get() == "sk-abc123")
  }

  @Test("set overwrites an existing value (update path)")
  func overwrite() {
    let store = makeStore()
    defer { store.set(nil) }
    #expect(store.set("first"))
    #expect(store.set("second"))
    #expect(store.get() == "second")
  }

  @Test("set trims surrounding whitespace")
  func trimsWhitespace() {
    let store = makeStore()
    defer { store.set(nil) }
    #expect(store.set("  sk-trim  \n"))
    #expect(store.get() == "sk-trim")
  }

  @Test("set(nil) deletes the stored value")
  func deleteWithNil() {
    let store = makeStore()
    defer { store.set(nil) }
    #expect(store.set("to-be-deleted"))
    #expect(store.set(nil))
    #expect(store.get() == nil)
  }

  @Test("set(whitespace) deletes, get returns nil")
  func deleteWithBlank() {
    let store = makeStore()
    defer { store.set(nil) }
    #expect(store.set("present"))
    #expect(store.set("   "))
    #expect(store.get() == nil)
  }
}
