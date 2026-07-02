import Testing

@testable import BlurtEngine

/// `PersistedSettings.allDefaultsKeys` exists so "add a store" and "add it to
/// every reset sweep" are the same edit. Pinning the roster here makes the
/// forgotten-half of that edit a test failure instead of a silently stale sweep.
@Suite("PersistedSettings")
struct PersistedSettingsTests {
  @Test("the reset roster names every engine store's defaults key")
  func rosterCoversEveryStore() {
    #expect(PersistedSettings.allDefaultsKeys.contains(TriggerKeyStore.defaultsKey))
    #expect(PersistedSettings.allDefaultsKeys.contains(SoundPackStore.defaultsKey))
    #expect(PersistedSettings.allDefaultsKeys.contains(KeyTermsStore.defaultsKey))
  }

  @Test("the roster carries no stale or duplicate keys")
  func rosterHasNoStrays() {
    // Exactly the three known stores: a removed store must leave the roster in
    // the same change, and a key listed twice would hint at a copy-paste slip.
    #expect(PersistedSettings.allDefaultsKeys.count == 3)
    #expect(Set(PersistedSettings.allDefaultsKeys).count == PersistedSettings.allDefaultsKeys.count)
  }
}
