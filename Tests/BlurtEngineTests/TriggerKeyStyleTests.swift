import Foundation
import Testing

@testable import BlurtEngine

/// Per-key styles: which trigger keys dictate (`TriggerKeyStyleStore`), and the
/// style one dictation uses without moving the main window's selection
/// (`PressStyle` over `StyleProfileStore.profile(for:)`).
@Suite("TriggerKeyStyle")
struct TriggerKeyStyleTests {
  private let defaults = freshDefaults()
  private let casual = StyleProfile(name: "Casual", instructions: "keep it breezy")
  private let formal = StyleProfile(name: "Formal", instructions: "no contractions")

  private var keyStyles: TriggerKeyStyleStore { TriggerKeyStyleStore(defaults: defaults) }

  /// A style store holding both profiles with Formal selected in the main window.
  private func formalSelected() -> StyleProfileStore {
    let store = StyleProfileStore(defaults: defaults)
    store.profiles = [casual, formal]
    store.activate(formal)
    return store
  }

  @Test("an untouched install binds exactly the one key, with the current style")
  func untouchedIsTodaysBehavior() {
    #expect(keyStyles.styles.isEmpty)
    #expect(keyStyles.enabledKeys == [.rightCommand])
    #expect(keyStyles.styleID(for: .rightCommand) == nil)
    TriggerKeyStore(defaults: defaults).triggerKey = .function
    #expect(keyStyles.enabledKeys == [.function])
  }

  @Test("styles round-trip, and a key given one dictates beside the bound key")
  func stylesRoundTripAndEnableKeys() {
    keyStyles.styles = [.rightOption: casual.id.uuidString, .function: TriggerKeyStyleStore.currentStyleID]
    #expect(TriggerKeyStyleStore(defaults: defaults).styles[.rightOption] == casual.id.uuidString)
    #expect(keyStyles.enabledKeys == [.rightCommand, .rightOption, .function])
    #expect(keyStyles.styleID(for: .rightOption) == casual.id.uuidString)
    #expect(keyStyles.styleID(for: .function) == nil)
    #expect(keyStyles.styleID(for: .rightCommand) == nil)
  }

  @Test("a corrupt value or an unknown keycode binds nothing new")
  func corruptOrUnknownDecodesToNothing() {
    #expect(TriggerKeyStyleStore.styles(decoding: "not json").isEmpty)
    #expect(TriggerKeyStyleStore.styles(decoding: #"{"12":"current","x":"current"}"#).isEmpty)
    #expect(TriggerKeyStyleStore.styles(decoding: #"{"61":"current"}"#) == [.rightOption: "current"])
  }

  @Test("a row shows Off, the current style, or a style that still exists")
  func rowChoice() {
    let profiles = [casual]
    let styles: [TriggerKey: String] = [.rightOption: casual.id.uuidString, .function: formal.id.uuidString]
    func choice(_ key: TriggerKey, _ styles: [TriggerKey: String]) -> String {
      TriggerKeyStyleStore.choice(for: key, bound: .rightCommand, styles: styles, profiles: profiles)
    }
    #expect(choice(.rightCommand, styles) == TriggerKeyStyleStore.currentStyleID)
    #expect(choice(.rightOption, styles) == casual.id.uuidString)
    // Formal was deleted: the row shows what a press now does.
    #expect(choice(.function, styles) == TriggerKeyStyleStore.currentStyleID)
    #expect(choice(.function, [:]) == "")
    #expect(choice(.function, [.function: StyleProfileStore.defaultStyleID]) == StyleProfileStore.defaultStyleID)
  }

  @Test("a key's style shapes one dictation and never moves the selection")
  func pressStyleOverridesWithoutPersisting() {
    let store = formalSelected()
    let press = PressStyle()
    #expect(press.instructions(from: store) == "no contractions")
    press.request(casual.id.uuidString)
    #expect(press.instructions(from: store) == "keep it breezy")
    #expect(press.styleName(from: store, enhanced: true) == "Casual")
    #expect(store.active == formal)
    press.request(StyleProfileStore.defaultStyleID)
    #expect(press.instructions(from: store) == nil)
    #expect(press.styleName(from: store, enhanced: true) == nil)
  }

  @Test("a mapped style since deleted falls back to the main window's selection")
  func deletedStyleFallsBackToSelection() {
    let store = formalSelected()
    #expect(store.profile(for: UUID().uuidString) == formal)
    #expect(store.profile(for: TriggerKeyStyleStore.currentStyleID) == formal)
  }

  @Test("the Recent row names the style its request used, not a later press's")
  func styleNameFollowsTheRequest() {
    let store = formalSelected()
    let press = PressStyle()
    press.request(casual.id.uuidString)
    _ = press.instructions(from: store)
    // A press refused while that dictation transcribes asks for another style.
    press.request(nil)
    #expect(press.styleName(from: store, enhanced: true) == "Casual")
    #expect(press.styleName(from: store, enhanced: false) == nil)
    #expect(press.instructions(from: store) == "no contractions")
    #expect(press.styleName(from: store, enhanced: true) == "Formal")
  }
}
