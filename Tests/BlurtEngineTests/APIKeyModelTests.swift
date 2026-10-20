import Testing

@testable import BlurtEngine

/// The shells' API-key model over an in-memory store — never the real Keychain
/// — and a validator that answers without the network.
@Suite("API key model")
@MainActor
struct APIKeyModelTests {
  @Test("a key AssemblyAI accepts is saved and flips the flag; a rejected one is not saved")
  func submit() async {
    let store = InMemoryAPIKeyStore()
    let model = APIKeyModel(keyStore: store) { key in key == "good" ? .valid : .invalid }
    #expect(!model.hasAPIKey)
    #expect(await model.submit("bad") == .invalid)
    #expect(!model.hasAPIKey)
    #expect(store.current == nil)
    #expect(await model.submit("good") == .valid)
    #expect(model.hasAPIKey)
    #expect(store.current == "good")
  }

  @Test("the readiness gate reads the store as it is now; a refresh catches the flag up")
  func readiness() {
    let store = InMemoryAPIKeyStore()
    let model = APIKeyModel(keyStore: store) { _ in .valid }
    let check = model.readinessCheck()
    #expect(check() == .apiKeyMissing)
    store.save("key")
    #expect(check() == nil)
    #expect(!model.hasAPIKey)
    model.refreshStatus()
    #expect(model.hasAPIKey)
  }

  @Test("save writes through the injected store, unvalidated, and flips the flag")
  func save() {
    let store = InMemoryAPIKeyStore()
    let model = APIKeyModel(keyStore: store) { _ in .invalid }
    #expect(model.save("typed"))
    #expect(model.hasAPIKey)
    #expect(model.current == "typed")
    #expect(model.storage.current == "typed")
  }

  @Test("clear deletes the stored key and drops the flag")
  func clear() {
    let store = InMemoryAPIKeyStore()
    let model = APIKeyModel(keyStore: store) { _ in .valid }
    model.save("key")
    #expect(model.clear())
    #expect(!model.hasAPIKey)
    #expect(store.current == nil)
  }
}
