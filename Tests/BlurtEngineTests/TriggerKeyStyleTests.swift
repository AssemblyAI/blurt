import Foundation
import Testing

@testable import BlurtEngine

/// What each trigger key does and how it's pressed (`TriggerKeyBindings`, over
/// `TriggerKeyStyleStore` and `TriggerKeyActivationStore`), and the style one
/// dictation uses without moving the main window's selection (`PressStyle`
/// over `StyleProfileStore.profile(for:)`).
@Suite("TriggerKeyBindings")
struct TriggerKeyStyleTests {
  private let defaults = freshDefaults()
  private let casual = StyleProfile(name: "Casual", instructions: "keep it breezy")
  private let formal = StyleProfile(name: "Formal", instructions: "no contractions")

  private var choices: TriggerKeyStyleStore { TriggerKeyStyleStore(defaults: defaults) }
  private var modes: TriggerKeyActivationStore { TriggerKeyActivationStore(defaults: defaults) }
  private var bindings: TriggerKeyBindings { TriggerKeyBindings(defaults: defaults) }

  /// A style store holding both profiles with Formal selected in the main window.
  private func formalSelected() -> StyleProfileStore {
    let store = StyleProfileStore(defaults: defaults)
    store.profiles = [casual, formal]
    store.activate(formal)
    return store
  }

  @Test("an untouched install: the bound key dictates, left ⌥ reads aloud, the rest are off")
  func untouchedDefaults() {
    #expect(defaults.string(forKey: TriggerKeyStyleStore.defaultsKey) == nil)
    #expect(bindings.enabledKeys == [.rightCommand, .leftOption])
    #expect(bindings.choice(for: .rightCommand) == .dictate)
    #expect(bindings.action(for: .leftOption) == .readAloud)
    // Left ⌘ is off: it's down for every shortcut and ⌘-click.
    #expect(bindings.action(for: .leftCommand) == .off)
    TriggerKeyStore(defaults: defaults).triggerKey = .function
    #expect(bindings.enabledKeys == [.function, .leftOption])
  }

  @Test("any key can read aloud or ask, and Off sticks where the default isn't Off")
  func actions() {
    choices.setChoice(.ask, for: .leftControl)
    choices.setChoice(.readAloud, for: .rightOption)
    choices.setChoice(.off, for: .leftOption)
    #expect(bindings.action(for: .leftControl) == .ask)
    #expect(bindings.action(for: .rightOption) == .readAloud)
    #expect(bindings.action(for: .leftOption) == .off)
    #expect(bindings.enabledKeys == [.rightCommand, .rightOption, .leftControl])
    // Back to their defaults: no entries left behind.
    choices.setChoice(.readAloud, for: .leftOption)
    choices.setChoice(.off, for: .rightOption)
    choices.setChoice(.off, for: .leftControl)
    #expect(defaults.string(forKey: TriggerKeyStyleStore.defaultsKey) == "{}")
  }

  @Test("choices keep the stored form styles had before read and ask")
  func rawForm() {
    for choice in [TriggerKeyChoice.off, .readAloud, .ask, .dictate, .dictate(style: UUID().uuidString)] {
      #expect(TriggerKeyChoice(raw: choice.raw) == choice)
    }
    #expect(TriggerKeyChoice(raw: "current") == .dictate)
  }

  @Test("the bound key dictates whatever its entry says")
  func boundKeyAlwaysDictates() {
    let bindings = TriggerKeyBindings(
      boundKeyCode: TriggerKey.rightCommand.keyCode, choicesRaw: #"{"54":"read-aloud"}"#, modesRaw: "",
      sharedModeRaw: "")
    #expect(bindings.choice(for: .rightCommand) == .dictate)
  }

  @Test("taking the bound key off dictation moves the binding to the next dictating key")
  func movingTheBinding() {
    choices.setChoice(.dictate(style: casual.id.uuidString), for: .function)
    #expect(choices.setChoice(.readAloud, for: .rightCommand))
    #expect(bindings.bound == .function)
    #expect(bindings.action(for: .rightCommand) == .readAloud)
    // The new bound key keeps the style it dictated with.
    #expect(bindings.choice(for: .function) == .dictate(style: casual.id.uuidString))
  }

  @Test("the only dictating key can't be taken off dictation")
  func lastDictatingKeyStays() {
    #expect(!choices.setChoice(.off, for: .rightCommand))
    #expect(bindings.bound == .rightCommand)
    #expect(bindings.dictatingKeys == [.rightCommand])
  }

  @Test("a corrupt value or an unknown keycode binds nothing new")
  func corruptOrUnknownDecodesToNothing() {
    #expect(TriggerKeyMap.decode("not json").isEmpty)
    #expect(TriggerKeyMap.decode(#"{"12":"current","x":"current"}"#).isEmpty)
    #expect(TriggerKeyMap.decode(#"{"61":"current"}"#) == [.rightOption: "current"])
  }

  @Test("a row shows Off, the main window's style, a style that still exists, read or ask")
  func rowChoice() {
    func bindings(_ raw: String) -> TriggerKeyBindings {
      TriggerKeyBindings(boundKeyCode: 54, choicesRaw: raw, modesRaw: "", sharedModeRaw: "")
    }
    let styled = bindings(#"{"61":"\#(casual.id.uuidString)","63":"\#(formal.id.uuidString)"}"#)
    #expect(styled.choice(for: .rightCommand, profiles: [casual]) == .dictate)
    #expect(styled.choice(for: .rightOption, profiles: [casual]) == .dictate(style: casual.id.uuidString))
    // Formal was deleted: the row shows what a press now does.
    #expect(styled.choice(for: .function, profiles: [casual]) == .dictate)
    #expect(bindings("").choice(for: .function, profiles: []) == .off)
    #expect(bindings("").choice(for: .leftOption, profiles: []) == .readAloud)
    let base = bindings(#"{"63":"\#(StyleProfileStore.defaultStyleID)","59":"ask"}"#)
    #expect(base.choice(for: .function, profiles: []) == .dictate(style: StyleProfileStore.defaultStyleID))
    #expect(base.choice(for: .leftControl, profiles: []) == .ask)
  }

  @Test("modes: a key's own, else left ⌥'s read is tap or hold, else the shared mode")
  func activations() {
    defaults.set(TriggerActivation.hold.rawValue, forKey: TriggerActivationStore.defaultsKey)
    choices.setChoice(.dictate(style: casual.id.uuidString), for: .rightOption)
    #expect(bindings.activation(for: .rightCommand) == .hold)
    #expect(bindings.activation(for: .leftOption) == .tapOrHold)
    #expect(bindings.activation(for: .rightOption) == .hold)
    modes.setActivation(.tap, for: .leftOption)
    modes.setActivation(.tap, for: .rightCommand)
    #expect(bindings.activation(for: .leftOption) == .tap)
    #expect(bindings.activation(for: .rightCommand) == .tap)
    // Right ⌥ has no mode of its own, so it follows the shared one.
    #expect(bindings.activations == [.rightCommand: .tap, .rightOption: .hold, .leftOption: .tap])
  }

  @Test("each key keeps its own mode when the binding moves")
  func modesStayWithTheirKeys() {
    choices.setChoice(.dictate, for: .rightOption)
    modes.setActivation(.tap, for: .rightOption)
    modes.setActivation(.hold, for: .rightCommand)
    choices.setChoice(.off, for: .rightCommand)
    #expect(bindings.bound == .rightOption)
    #expect(bindings.activation(for: .rightOption) == .tap)
  }

  @Test("each press resolves under its own key's mode")
  func routerAppliesEachKeysMode() {
    let command = TriggerKey.rightCommand.keyCode
    let left = TriggerKey.leftCommand.keyCode
    var router = DictationKeyRouter(activations: [command: .hold, left: .tap])
    // A long press of the tap key still latches; a short press of the hold key stops.
    #expect(router.handle(.flagsChanged(keyCode: left, triggerFlagIsOn: true), at: .zero) == .start)
    #expect(router.handle(.flagsChanged(keyCode: left, triggerFlagIsOn: false), at: .seconds(3)) == .latch)
    #expect(router.handle(.flagsChanged(keyCode: left, triggerFlagIsOn: true), at: .seconds(4)) == .none)
    #expect(router.handle(.flagsChanged(keyCode: left, triggerFlagIsOn: false), at: .seconds(5)) == .stop)
    #expect(router.handle(.flagsChanged(keyCode: command, triggerFlagIsOn: true), at: .seconds(6)) == .start)
    #expect(
      router.handle(.flagsChanged(keyCode: command, triggerFlagIsOn: false), at: .seconds(6) + .milliseconds(100))
        == .stop)
  }

  @Test("changing another key's mode keeps a live recording; changing the active key's discards it")
  func rebindModesMidRecording() {
    let command = TriggerKey.rightCommand.keyCode
    let left = TriggerKey.leftCommand.keyCode
    var router = DictationKeyRouter(activations: [command: .tap, left: .tap])
    _ = router.handle(.flagsChanged(keyCode: command, triggerFlagIsOn: true), at: .zero)
    _ = router.handle(.flagsChanged(keyCode: command, triggerFlagIsOn: false), at: .milliseconds(100))
    let other = router.rebind(activations: [command: .tap, left: .hold])
    #expect(!other)
    let active = router.rebind(activations: [command: .hold, left: .hold])
    #expect(active)
  }

  /// Raw `CGEventFlags` as macOS reports a lone press of each key: the generic
  /// modifier bit, the key's own device bit, and the non-coalesced bit (0x100).
  private static let pressedFlags: [TriggerKey: UInt64] = [
    .rightCommand: 0x10_0000 | 0x10 | 0x100,
    .rightOption: 0x8_0000 | 0x40 | 0x100,
    .function: 0x80_0000 | 0x100,
    .leftCommand: 0x10_0000 | 0x08 | 0x100,
    .leftOption: 0x8_0000 | 0x20 | 0x100,
    .leftControl: 0x4_0000 | 0x01 | 0x100,
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

  @Test("a router built from the bindings fires for every key that does something")
  func routerFromBindingsFires() throws {
    choices.setChoice(.dictate(style: casual.id.uuidString), for: .rightOption)
    choices.setChoice(.dictate, for: .function)
    var router = DictationKeyRouter(
      activations: Dictionary(uniqueKeysWithValues: bindings.activations.map { ($0.key.keyCode, $0.value) }))
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
    choices.setChoice(.dictate(style: casual.id.uuidString), for: .rightOption)
    choices.setChoice(.dictate(style: StyleProfileStore.defaultStyleID), for: .function)
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
    #expect(store.profile(for: TriggerKeyChoice.mainWindowStyle) == formal)
  }
}
