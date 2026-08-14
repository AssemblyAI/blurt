import Testing

@testable import BlurtEngine

/// The single-`Int`-slot encoding behind `TriggerKeyStore`: both binding
/// families round-trip through `persistedValue`/`fromPersisted`, their codes
/// can't collide, and garbage decodes to the right-⌘ default rather than an
/// invalid selection.
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
    bindings += (TriggerBinding.minimumMouseButton...TriggerBinding.maximumMouseButton)
      .map { TriggerBinding.mouseButton($0) }
    for binding in bindings {
      #expect(TriggerBinding.fromPersisted(binding.persistedValue) == binding)
    }
  }

  @Test("the two families' persisted codes are disjoint")
  func encodingsAreDisjoint() {
    // The whole zero-migration scheme rests on this: a mouse code must never
    // read as a modifier keycode, and vice versa.
    let modifierCodes = Set(TriggerKey.allCases.map(\.rawValue))
    let mouseCodes = Set(
      (TriggerBinding.minimumMouseButton...TriggerBinding.maximumMouseButton)
        .map { TriggerBinding.mouseButton($0).persistedValue })
    #expect(modifierCodes.isDisjoint(with: mouseCodes))
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

  @Test("a bare keyboard keycode falls back to right ⌘ — keys aren't bindable")
  func keyboardKeycodesFallBack() {
    #expect(TriggerBinding.fromPersisted(0x31) == .modifier(.rightCommand))  // Space
    #expect(TriggerBinding.fromPersisted(96) == .modifier(.rightCommand))  // F5
    #expect(TriggerBinding.fromPersisted(122) == .modifier(.rightCommand))  // F1
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

  @Test("labels name the binding the way the UI should")
  func labels() {
    #expect(TriggerBinding.modifier(.rightCommand).label == "right ⌘")
    // 1-based, the numbering macOS and pointing-device vendors show users:
    // button number 2 is the middle button, "Mouse 3".
    #expect(TriggerBinding.mouseButton(2).label == "Mouse 3")
    #expect(TriggerBinding.mouseButton(3).label == "Mouse 4")
  }
}
