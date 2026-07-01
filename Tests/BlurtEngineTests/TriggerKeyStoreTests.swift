import Foundation
import Testing

@testable import BlurtEngine

@Suite("TriggerKeyStore")
struct TriggerKeyStoreTests {
  private func freshDefaults() -> UserDefaults {
    // A throwaway suite keeps the test from touching the real app domain.
    let name = "TriggerKeyStoreTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }

  @Test("defaults to right command when unset")
  func defaultsToRightCommand() {
    let store = TriggerKeyStore(defaults: freshDefaults())
    #expect(store.triggerKey == .rightCommand)
  }

  @Test("persists and reads back a chosen key")
  func roundTrips() {
    let defaults = freshDefaults()
    let store = TriggerKeyStore(defaults: defaults)
    store.triggerKey = .rightOption
    #expect(TriggerKeyStore(defaults: defaults).triggerKey == .rightOption)
  }

  @Test("an unknown stored code falls back to the default")
  func unknownFallsBack() {
    let defaults = freshDefaults()
    defaults.set(123, forKey: "BlurtTriggerKeyCode")
    #expect(TriggerKeyStore(defaults: defaults).triggerKey == .rightCommand)
  }
}
