import Foundation
import Testing

@testable import BlurtEngine

@Suite("EscapeCancelStore")
struct EscapeCancelStoreTests {
  @Test("defaults to off when unset")
  func defaultsToOff() {
    #expect(!EscapeCancelStore(defaults: freshDefaults()).isEnabled)
  }

  /// The store is read-only, so what it has to agree with is the slot the Settings
  /// toggle writes through `@AppStorage` — which is what this seeds.
  @Test("reads back the switch the Settings toggle writes")
  func readsBackTheToggledSlot() {
    let defaults = freshDefaults()
    let store = EscapeCancelStore(defaults: defaults)
    defaults.set(true, forKey: EscapeCancelStore.defaultsKey)
    #expect(store.isEnabled)
    defaults.set(false, forKey: EscapeCancelStore.defaultsKey)
    #expect(!store.isEnabled)
  }

  @Test("developer mode doesn't turn it on, or off")
  func independentOfDeveloperMode() {
    let defaults = freshDefaults()
    let store = EscapeCancelStore(defaults: defaults)
    defaults.set(true, forKey: DeveloperModeStore.defaultsKey)
    #expect(!store.isEnabled)
    defaults.set(true, forKey: EscapeCancelStore.defaultsKey)
    defaults.set(false, forKey: DeveloperModeStore.defaultsKey)
    #expect(store.isEnabled)
  }
}
