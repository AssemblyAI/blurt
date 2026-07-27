import Foundation
import Testing

@testable import BlurtEngine

/// The injectable key-storage seam. Only the in-memory conformance and the
/// protocol's derived `hasKey` are exercised here — `ProductionAPIKeyStore`
/// forwards to the real Keychain item, which tests must never touch (the
/// Keychain plumbing itself is covered by `KeychainStoreTests` against an
/// isolated service/account).
@Suite("APIKeyGateway")
struct APIKeyGatewayTests {

  @Test("in-memory store round-trips a key, trimmed")
  func inMemoryRoundTrip() {
    let store = InMemoryAPIKeyStore()
    #expect(store.current == nil)
    #expect(!store.hasKey)

    #expect(store.save("  sk-123  "))
    #expect(store.current == "sk-123")
    #expect(store.hasKey)
  }

  @Test("nil, empty, and whitespace writes all clear the stored key")
  func blankWritesClear() {
    for clearing in [nil, "", "   \n"] as [String?] {
      let store = InMemoryAPIKeyStore()
      store.save("sk-123")
      store.save(clearing)
      #expect(store.current == nil, "expected \(String(describing: clearing)) to clear the key")
      #expect(!store.hasKey)
    }
  }

  @Test("hasKey is derived from `current` for any conformance")
  func hasKeyDerivesFromCurrent() {
    struct FixedGateway: APIKeyGateway {
      let value: String?
      var current: String? { value }
      @discardableResult func save(_ key: String?) -> Bool { false }
    }
    #expect(FixedGateway(value: "sk-123").hasKey)
    #expect(!FixedGateway(value: nil).hasKey)
  }
}
