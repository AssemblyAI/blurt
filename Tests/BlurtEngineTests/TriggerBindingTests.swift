import Testing

@testable import BlurtEngine

/// The single-`Int`-slot encoding behind `TriggerKeyStore`: every binding kind
/// round-trips through `persistedValue`/`fromPersisted`, the three families'
/// codes can't collide, and garbage decodes to the right-⌘ default rather than
/// an invalid selection.
@Suite("TriggerBinding")
struct TriggerBindingTests {
  @Test("modifier bindings persist as their bare keycode — the pre-Custom encoding")
  func modifierEncodingIsUnchanged() {
    // Zero migration: an install that stored 54/61/63 before Custom bindings
    // existed must decode to the same modifier afterwards.
    #expect(TriggerBinding.modifier(.rightCommand).persistedValue == 54)
    #expect(TriggerBinding.modifier(.rightOption).persistedValue == 61)
    #expect(TriggerBinding.modifier(.function).persistedValue == 63)
    #expect(TriggerBinding.fromPersisted(54) == .modifier(.rightCommand))
    #expect(TriggerBinding.fromPersisted(61) == .modifier(.rightOption))
    #expect(TriggerBinding.fromPersisted(63) == .modifier(.function))
  }

  @Test("every binding kind round-trips through the persisted slot")
  func roundTrips() {
    var bindings = TriggerKey.allCases.map { TriggerBinding.modifier($0) }
    bindings += TriggerBinding.functionKeyLabels.keys.map { TriggerBinding.key(code: $0) }
    bindings += (TriggerBinding.minimumMouseButton...TriggerBinding.maximumMouseButton)
      .map { TriggerBinding.mouseButton($0) }
    for binding in bindings {
      #expect(TriggerBinding.fromPersisted(binding.persistedValue) == binding)
    }
  }

  @Test("the three families' persisted codes are pairwise disjoint")
  func encodingsAreDisjoint() {
    // The whole zero-migration scheme rests on this: an F-key keycode must never
    // read as a modifier, and a mouse code must never read as either.
    let modifierCodes = Set(TriggerKey.allCases.map(\.rawValue))
    let functionKeyCodes = Set(TriggerBinding.functionKeyLabels.keys)
    let mouseCodes = Set(
      (TriggerBinding.minimumMouseButton...TriggerBinding.maximumMouseButton)
        .map { TriggerBinding.mouseButton($0).persistedValue })
    #expect(modifierCodes.isDisjoint(with: functionKeyCodes))
    #expect(modifierCodes.isDisjoint(with: mouseCodes))
    #expect(functionKeyCodes.isDisjoint(with: mouseCodes))
  }

  @Test("an unset slot decodes to the right-⌘ default")
  func unsetFallsBack() {
    // UserDefaults reads an absent integer as 0.
    #expect(TriggerBinding.fromPersisted(0) == .modifier(.rightCommand))
  }

  @Test("a persisted keycode from a removed option falls back to right ⌘")
  func removedOptionsFallBack() {
    // right ⌃ (62) and Caps Lock (57) were dropped as options; anyone who had
    // one saved must decode to the default rather than an invalid selection.
    #expect(TriggerBinding.fromPersisted(62) == .modifier(.rightCommand))
    #expect(TriggerBinding.fromPersisted(57) == .modifier(.rightCommand))
  }

  @Test("a printable keycode falls back to right ⌘ — only F-keys are bindable")
  func printableKeycodeFallsBack() {
    #expect(TriggerBinding.fromPersisted(0x00) == .modifier(.rightCommand))  // A… also the unset 0
    #expect(TriggerBinding.fromPersisted(0x31) == .modifier(.rightCommand))  // Space
  }

  @Test("a mouse code outside the bindable buttons falls back to right ⌘")
  func outOfRangeMouseCodesFallBack() {
    let base = TriggerBinding.mouseButtonCodeBase
    #expect(TriggerBinding.fromPersisted(base + 0) == .modifier(.rightCommand))  // left click
    #expect(TriggerBinding.fromPersisted(base + 1) == .modifier(.rightCommand))  // right click
    #expect(TriggerBinding.fromPersisted(base + 32) == .modifier(.rightCommand))  // past CGEvent's range
    #expect(TriggerBinding.fromPersisted(base + 2) == .mouseButton(2))  // first bindable
    #expect(TriggerBinding.fromPersisted(base + 31) == .mouseButton(31))  // last bindable
  }

  @Test("keyBinding(forKeyCode:) allows exactly the F-keys")
  func keyBindingPolicy() {
    #expect(TriggerBinding.keyBinding(forKeyCode: 96) == .key(code: 96))  // F5
    #expect(TriggerBinding.keyBinding(forKeyCode: 122) == .key(code: 122))  // F1
    #expect(TriggerBinding.keyBinding(forKeyCode: 90) == .key(code: 90))  // F20
    #expect(TriggerBinding.keyBinding(forKeyCode: 0x00) == nil)  // A — would type
    #expect(TriggerBinding.keyBinding(forKeyCode: 49) == nil)  // Space — would type
    #expect(TriggerBinding.keyBinding(forKeyCode: 53) == nil)  // Esc — cancels capture
    #expect(TriggerBinding.keyBinding(forKeyCode: 57) == nil)  // Caps Lock
    #expect(TriggerBinding.keyBinding(forKeyCode: 54) == nil)  // right ⌘ is a modifier, not a key
  }

  @Test("mouseButtonBinding(forButton:) refuses the left and right click")
  func mouseBindingPolicy() {
    #expect(TriggerBinding.mouseButtonBinding(forButton: 0) == nil)  // left
    #expect(TriggerBinding.mouseButtonBinding(forButton: 1) == nil)  // right
    #expect(TriggerBinding.mouseButtonBinding(forButton: 2) == .mouseButton(2))  // "Mouse 3"
    #expect(TriggerBinding.mouseButtonBinding(forButton: 3) == .mouseButton(3))  // "Mouse 4"
    #expect(TriggerBinding.mouseButtonBinding(forButton: 31) == .mouseButton(31))
    #expect(TriggerBinding.mouseButtonBinding(forButton: 32) == nil)  // past CGEvent's range
    #expect(TriggerBinding.mouseButtonBinding(forButton: -1) == nil)
  }

  @Test("all twenty F-keys are bindable, F1 through F20")
  func functionKeyTableIsComplete() {
    #expect(TriggerBinding.functionKeyLabels.count == 20)
    let labels = Set(TriggerBinding.functionKeyLabels.values)
    for number in 1...20 {
      #expect(labels.contains("F\(number)"), "F\(number) missing from the bindable set")
    }
  }

  @Test("labels name the binding the way the UI should")
  func labels() {
    #expect(TriggerBinding.modifier(.rightCommand).label == "right ⌘")
    #expect(TriggerBinding.key(code: 96).label == "F5")
    #expect(TriggerBinding.key(code: 64).label == "F17")
    // 1-based, the numbering macOS and pointing-device vendors show users:
    // button number 2 is the middle button, "Mouse 3".
    #expect(TriggerBinding.mouseButton(2).label == "Mouse 3")
    #expect(TriggerBinding.mouseButton(3).label == "Mouse 4")
    // A directly constructed non-F-key code (fromPersisted never produces one)
    // still renders something rather than trapping.
    #expect(TriggerBinding.key(code: 1).label == "F?")
  }
}
