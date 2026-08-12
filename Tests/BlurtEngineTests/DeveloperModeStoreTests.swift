import Foundation
import Testing

@testable import BlurtEngine

@Suite("DeveloperModeStore")
struct DeveloperModeStoreTests {
  @Test("defaults to off when unset")
  func defaultsToOff() {
    #expect(!DeveloperModeStore(defaults: freshDefaults()).isEnabled)
  }

  /// The store is read-only, so what it has to agree with is the slot the Settings
  /// toggle writes through `@AppStorage` — which is what this seeds, rather than a
  /// setter no production code calls.
  @Test("reads back the switch the Settings toggle writes")
  func readsBackTheToggledSlot() {
    let defaults = freshDefaults()
    let store = DeveloperModeStore(defaults: defaults)
    defaults.set(true, forKey: DeveloperModeStore.defaultsKey)
    #expect(store.isEnabled)
    // Same instance: the store reads through to `defaults` on every access rather
    // than snapshotting at init, so a Settings change lands without a rebuild.
    defaults.set(false, forKey: DeveloperModeStore.defaultsKey)
    #expect(!store.isEnabled)
  }
}
