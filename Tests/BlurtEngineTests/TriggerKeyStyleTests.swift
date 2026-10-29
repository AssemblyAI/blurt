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
    #expect(keyStyles.styles[.rightCommand] == nil)
    TriggerKeyStore(defaults: defaults).triggerKey = .function
    #expect(keyStyles.enabledKeys == [.function])
  }

  @Test("styles round-trip, and a key given one dictates beside the bound key")
  func stylesRoundTripAndEnableKeys() {
    #expect(keyStyles.setStyle(casual.id.uuidString, for: .rightOption))
    #expect(keyStyles.setStyle(TriggerKeyStyleStore.currentStyleID, for: .function))
    #expect(TriggerKeyStyleStore(defaults: defaults).styles[.rightOption] == casual.id.uuidString)
    #expect(keyStyles.enabledKeys == [.rightCommand, .rightOption, .function])
    #expect(keyStyles.styles[.function] == TriggerKeyStyleStore.currentStyleID)
    #expect(keyStyles.styles[.rightCommand] == nil)
  }

  @Test("only turning a key on or off reports a rebind; a style change doesn't")
  func setStyleReportsEnabledChanges() {
    #expect(keyStyles.setStyle(TriggerKeyStyleStore.currentStyleID, for: .rightOption))
    #expect(!keyStyles.setStyle(casual.id.uuidString, for: .rightOption))
    #expect(keyStyles.setStyle("", for: .rightOption))
    #expect(!keyStyles.setStyle("", for: .rightOption))
    #expect(keyStyles.styles.isEmpty)
    // The bound key dictates either way, so giving it a style rebinds nothing.
    #expect(!keyStyles.setStyle(formal.id.uuidString, for: .rightCommand))
  }

  @Test("the bound key set back to the main window's style stores no entry")
  func boundKeyDefaultStoresNothing() {
    _ = keyStyles.setStyle(casual.id.uuidString, for: .rightCommand)
    _ = keyStyles.setStyle(TriggerKeyStyleStore.currentStyleID, for: .rightCommand)
    #expect(keyStyles.styles.isEmpty)
  }

  @Test("rebinding stops the key moved away from dictating, and keeps the others")
  func rebindClearsTheOldBoundKey() {
    _ = keyStyles.setStyle(casual.id.uuidString, for: .rightCommand)
    _ = keyStyles.setStyle(formal.id.uuidString, for: .function)
    TriggerKeyStore(defaults: defaults).triggerKey = .rightOption
    #expect(keyStyles.enabledKeys == [.rightOption, .function])
    #expect(keyStyles.styles == [.function: formal.id.uuidString])
  }

  @Test("a key bound away and back gets its style back")
  func rebindBackRestoresTheStyle() {
    let keys = TriggerKeyStore(defaults: defaults)
    _ = keyStyles.setStyle(casual.id.uuidString, for: .rightCommand)
    keys.triggerKey = .rightOption
    #expect(keyStyles.enabledKeys == [.rightOption])
    keys.triggerKey = .rightCommand
    #expect(keyStyles.enabledKeys == [.rightCommand])
    #expect(keyStyles.styles == [.rightCommand: casual.id.uuidString])
  }

  @Test("a key set up as an extra before it was bound is an extra again once unbound")
  func extraKeySurvivesBeingBound() {
    let keys = TriggerKeyStore(defaults: defaults)
    _ = keyStyles.setStyle(casual.id.uuidString, for: .rightOption)
    keys.triggerKey = .rightOption
    // Bound, it keeps dictating with the style it had as an extra.
    #expect(keyStyles.styles[.rightOption] == casual.id.uuidString)
    _ = keyStyles.setStyle(formal.id.uuidString, for: .rightOption)
    keys.triggerKey = .rightCommand
    #expect(keyStyles.enabledKeys == [.rightCommand, .rightOption])
    #expect(keyStyles.styles[.rightOption] == casual.id.uuidString)
    // And bound again, the style it was given while bound.
    keys.triggerKey = .rightOption
    #expect(keyStyles.styles[.rightOption] == formal.id.uuidString)
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

  /// Raw `CGEventFlags` as macOS reports a lone press of each key: the generic
  /// modifier bit, the key's own device bit, and the non-coalesced bit (0x100).
  private static let pressedFlags: [TriggerKey: UInt64] = [
    .rightCommand: 0x10_0000 | 0x10 | 0x100,
    .rightOption: 0x8_0000 | 0x40 | 0x100,
    .function: 0x80_0000 | 0x100,
  ]

  @Test("each trigger key's own flag bit reads as down, and another key's doesn't")
  func flagsReadPerKey() throws {
    for key in TriggerKey.allCases {
      let flags = try #require(Self.pressedFlags[key])
      let down = DictationKeyRouter.Event.fromFlags(keyCode: key.keyCode, rawFlags: flags)
      let up = DictationKeyRouter.Event.fromFlags(keyCode: key.keyCode, rawFlags: 0x100)
      #expect(down == .flagsChanged(keyCode: key.keyCode, triggerFlagIsOn: true))
      #expect(up == .flagsChanged(keyCode: key.keyCode, triggerFlagIsOn: false))
    }
    // Right ⌥ released while right ⌘ is still held: ⌥'s event must read as up.
    let option = TriggerKey.rightOption.keyCode
    let commandHeld = try #require(Self.pressedFlags[.rightCommand])
    let optionUp = DictationKeyRouter.Event.fromFlags(keyCode: option, rawFlags: commandHeld)
    #expect(optionUp == .flagsChanged(keyCode: option, triggerFlagIsOn: false))
  }

  @Test("a router built from the store dictates with every key given a style")
  func routerFromStoreFiresForStyledKeys() throws {
    _ = keyStyles.setStyle(casual.id.uuidString, for: .rightOption)
    _ = keyStyles.setStyle(TriggerKeyStyleStore.currentStyleID, for: .function)
    var router = DictationKeyRouter(triggerKeyCodes: Set(keyStyles.enabledKeys.map(\.keyCode)))
    for (index, key) in [TriggerKey.rightOption, .function, .rightCommand].enumerated() {
      let start = Duration.seconds(index * 10)
      let flags = try #require(Self.pressedFlags[key])
      let down = DictationKeyRouter.Event.fromFlags(keyCode: key.keyCode, rawFlags: flags)
      #expect(router.handle(down, at: start) == .start)
      #expect(router.activeKeyCode == key.keyCode)
      let up = DictationKeyRouter.Event.fromFlags(keyCode: key.keyCode, rawFlags: 0x100)
      #expect(router.handle(up, at: start + .seconds(2)) == .stop)
    }
  }

  @Test("a key's style shapes one dictation and never moves the selection")
  func pressStyleOverridesWithoutPersisting() {
    let store = formalSelected()
    _ = keyStyles.setStyle(casual.id.uuidString, for: .rightOption)
    _ = keyStyles.setStyle(StyleProfileStore.defaultStyleID, for: .function)
    _ = keyStyles.setStyle(TriggerKeyStyleStore.currentStyleID, for: .rightCommand)
    let formalStyle = PressStyle(instructions: "no contractions", name: "Formal")
    #expect(PressStyle(key: nil, defaults: defaults) == formalStyle)
    #expect(PressStyle(key: .rightCommand, defaults: defaults) == formalStyle)
    #expect(
      PressStyle(key: .rightOption, defaults: defaults)
        == PressStyle(instructions: "keep it breezy", name: "Casual"))
    #expect(store.profile(for: nil) == formal)
    #expect(PressStyle(key: .function, defaults: defaults) == .none)
  }

  @Test("with enhanced transcripts off a style still rides the request but names no row")
  func enhancedOffNamesNothing() {
    _ = formalSelected()
    defaults.set(false, forKey: EnhancedTranscriptsStore.defaultsKey)
    #expect(
      PressStyle(key: nil, defaults: defaults)
        == PressStyle(instructions: "no contractions", name: nil))
  }

  @Test("a mapped style since deleted falls back to the main window's selection")
  func deletedStyleFallsBackToSelection() {
    let store = formalSelected()
    #expect(store.profile(for: UUID().uuidString) == formal)
    #expect(store.profile(for: TriggerKeyStyleStore.currentStyleID) == formal)
  }
}
