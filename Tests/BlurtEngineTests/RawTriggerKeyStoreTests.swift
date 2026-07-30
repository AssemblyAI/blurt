import Foundation
import Testing

@testable import BlurtEngine

@Suite("RawTriggerKeyStore")
struct RawTriggerKeyStoreTests {
  @Test("defaults to right option when unset")
  func defaultsToRightOption() {
    // The raw trigger's default is right ⌥, distinct from the cleaned trigger's
    // right ⌘ (`TriggerKeyStore`), so the two keys start out different.
    let store = RawTriggerKeyStore(defaults: freshDefaults())
    #expect(store.triggerKey == .rightOption)
  }

  @Test("persists and reads back a chosen key")
  func roundTrips() {
    let defaults = freshDefaults()
    let store = RawTriggerKeyStore(defaults: defaults)
    store.triggerKey = .function
    #expect(RawTriggerKeyStore(defaults: defaults).triggerKey == .function)
  }

  @Test("an unknown stored code falls back to right option")
  func unknownFallsBack() {
    // Unlike TriggerKeyStore (which falls back to right ⌘ via `fromPersisted`),
    // the raw store applies its own right-⌥ fallback for an unknown or 0 code.
    let defaults = freshDefaults()
    defaults.set(123, forKey: RawTriggerKeyStore.defaultsKey)
    #expect(RawTriggerKeyStore(defaults: defaults).triggerKey == .rightOption)
  }
}
