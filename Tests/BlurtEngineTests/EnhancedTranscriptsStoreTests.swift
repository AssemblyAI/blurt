import Foundation
import Testing

@testable import BlurtEngine

@Suite("EnhancedTranscriptsStore")
struct EnhancedTranscriptsStoreTests {
  @Test("defaults to on when unset")
  func defaultsToOn() {
    // The cleanup rewrite is the product's default behavior — an unset key
    // must read as enabled, unlike the bool stores that default to off.
    #expect(EnhancedTranscriptsStore(defaults: freshDefaults()).isEnabled)
  }

  /// The store is read-only, so what it has to agree with is the slot the Settings
  /// toggle writes through `@AppStorage` — which is what this seeds, rather than a
  /// setter no production code calls.
  @Test("reads back the switch the Settings toggle writes")
  func readsBackTheToggledSlot() {
    let defaults = freshDefaults()
    let store = EnhancedTranscriptsStore(defaults: defaults)
    defaults.set(false, forKey: EnhancedTranscriptsStore.defaultsKey)
    #expect(!store.isEnabled)
    // Same instance: the store reads through to `defaults` on every access, which is
    // what lets `AssemblyAITranscriber` pick the change up on the very next request.
    defaults.set(true, forKey: EnhancedTranscriptsStore.defaultsKey)
    #expect(store.isEnabled)
  }
}
