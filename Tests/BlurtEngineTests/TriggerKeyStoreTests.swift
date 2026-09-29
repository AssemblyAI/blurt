import Foundation
import Testing

@testable import BlurtEngine

@Suite("TriggerKeyStore")
struct TriggerKeyStoreTests {
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
    defaults.set(123, forKey: TriggerKeyStore.defaultsKey)
    #expect(TriggerKeyStore(defaults: defaults).triggerKey == .rightCommand)
  }

  @Test("an fn binding saved before fn was removed migrates to right ⌘, once")
  func staleFunctionMigrates() {
    let defaults = freshDefaults()
    defaults.set(TriggerKey.function.rawValue, forKey: TriggerKeyStore.defaultsKey)
    let store = TriggerKeyStore(defaults: defaults)
    store.migrateStaleFunctionBinding()
    #expect(store.triggerKey == .rightCommand)
    // A deliberate pick after the migration sticks, across launches and resets.
    store.triggerKey = .function
    PersistedSettings.resetAll(in: defaults)
    store.triggerKey = .function
    store.migrateStaleFunctionBinding()
    #expect(store.triggerKey == .function)
  }

  @Test("the migration leaves other bindings and fresh installs alone")
  func migrationLeavesOthers() {
    let defaults = freshDefaults()
    let store = TriggerKeyStore(defaults: defaults)
    store.migrateStaleFunctionBinding()
    #expect(defaults.object(forKey: TriggerKeyStore.defaultsKey) == nil)
    let other = freshDefaults()
    TriggerKeyStore(defaults: other).triggerKey = .rightOption
    TriggerKeyStore(defaults: other).migrateStaleFunctionBinding()
    #expect(TriggerKeyStore(defaults: other).triggerKey == .rightOption)
  }
}
