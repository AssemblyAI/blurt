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

  @Test("persists and reads back the switch")
  func roundTrips() {
    let defaults = freshDefaults()
    let store = EnhancedTranscriptsStore(defaults: defaults)
    store.isEnabled = false
    #expect(!EnhancedTranscriptsStore(defaults: defaults).isEnabled)
    store.isEnabled = true
    #expect(EnhancedTranscriptsStore(defaults: defaults).isEnabled)
  }
}
