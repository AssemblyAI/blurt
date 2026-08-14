import Foundation
import Testing

@testable import BlurtEngine

@Suite("TriggerKeyStore")
struct TriggerKeyStoreTests {
  @Test("defaults to right command when unset")
  func defaultsToRightCommand() {
    let store = TriggerKeyStore(defaults: freshDefaults())
    #expect(store.triggerBinding == .modifier(.rightCommand))
  }

  @Test("persists and reads back a chosen modifier")
  func roundTripsAModifier() {
    let defaults = freshDefaults()
    let store = TriggerKeyStore(defaults: defaults)
    store.triggerBinding = .modifier(.rightOption)
    #expect(TriggerKeyStore(defaults: defaults).triggerBinding == .modifier(.rightOption))
  }

  @Test("persists and reads back a custom F-key binding")
  func roundTripsAKeyBinding() {
    let defaults = freshDefaults()
    let store = TriggerKeyStore(defaults: defaults)
    store.triggerBinding = .key(code: 96)  // F5
    #expect(TriggerKeyStore(defaults: defaults).triggerBinding == .key(code: 96))
  }

  @Test("persists and reads back a custom mouse-button binding")
  func roundTripsAMouseBinding() {
    let defaults = freshDefaults()
    let store = TriggerKeyStore(defaults: defaults)
    store.triggerBinding = .mouseButton(3)  // "Mouse 4"
    #expect(TriggerKeyStore(defaults: defaults).triggerBinding == .mouseButton(3))
  }

  @Test("an unknown stored code falls back to the default")
  func unknownFallsBack() {
    let defaults = freshDefaults()
    defaults.set(123, forKey: TriggerKeyStore.defaultsKey)
    #expect(TriggerKeyStore(defaults: defaults).triggerBinding == .modifier(.rightCommand))
  }

  @Test("a modifier keycode stored before Custom bindings existed still decodes")
  func preCustomSlotStillDecodes() {
    // The store has always written the bare keycode for modifiers; the
    // TriggerBinding encoding must keep reading those installs unchanged.
    let defaults = freshDefaults()
    defaults.set(61, forKey: TriggerKeyStore.defaultsKey)  // right ⌥, pre-Custom form
    #expect(TriggerKeyStore(defaults: defaults).triggerBinding == .modifier(.rightOption))
  }
}
