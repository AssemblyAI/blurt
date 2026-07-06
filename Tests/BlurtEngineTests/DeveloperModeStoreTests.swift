import Foundation
import Testing

@testable import BlurtEngine

@Suite("DeveloperModeStore")
struct DeveloperModeStoreTests {
  @Test("defaults to off when unset")
  func defaultsToOff() {
    #expect(!DeveloperModeStore(defaults: freshDefaults()).isEnabled)
  }

  @Test("persists and reads back the switch")
  func roundTrips() {
    let defaults = freshDefaults()
    let store = DeveloperModeStore(defaults: defaults)
    store.isEnabled = true
    #expect(DeveloperModeStore(defaults: defaults).isEnabled)
    store.isEnabled = false
    #expect(!DeveloperModeStore(defaults: defaults).isEnabled)
  }
}
