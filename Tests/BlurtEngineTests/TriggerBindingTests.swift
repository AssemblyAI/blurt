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
    #expect(TriggerBinding.fromPersisted(54) == .modifier(.rightCommand))
    #expect(TriggerBinding.fromPersisted(61) == .modifier(.rightOption))
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
    // right ⌃ (62) and Caps Lock (57) were never options; anyone who had one
    // saved must decode to the default rather than an invalid selection.
    #expect(TriggerBinding.fromPersisted(62) == .modifier(.rightCommand))
    #expect(TriggerBinding.fromPersisted(57) == .modifier(.rightCommand))
  }

  /// `fn` was a third modifier option and was removed. Its keycode gets a
  /// **deliberate** landing spot rather than the generic right-⌘ fallback: right
  /// ⌥ is the other right-side modifier, so an install that had `fn` keeps a
  /// one-key trigger on the same side of the keyboard.
  @Test("a persisted fn (the removed option) migrates to right ⌥, not the default")
  func persistedFunctionKeyMigratesToRightOption() {
    #expect(TriggerBinding.legacyFunctionKeyCode == 63)
    #expect(TriggerBinding.fromPersisted(63) == .modifier(.rightOption))
    // And it is genuinely a migration, not a decode: `fn` is no longer a case.
    #expect(TriggerKey(rawValue: 63) == nil)
  }

  // MARK: - Chords

  @Test("a chord round-trips through the packed slot, keycode and modifiers intact")
  func chordRoundTrips() {
    let chord = TriggerBinding.chord(keyCode: 2, modifiers: [.control, .option])  // ⌃⌥D
    let packed = chord.persistedValue
    #expect(packed > TriggerBinding.chordCodeBase)
    #expect(TriggerBinding.fromPersisted(packed) == chord)
  }

  @Test("every modifier combination round-trips for a representative key")
  func everyModifierSetRoundTrips() {
    let keyCode = 2  // D
    for bits in 1...TriggerBinding.ChordModifiers.all.rawValue {
      let modifiers = TriggerBinding.ChordModifiers(rawValue: bits)
      let chord = TriggerBinding.chord(keyCode: keyCode, modifiers: modifiers)
      #expect(TriggerBinding.fromPersisted(chord.persistedValue) == chord)
    }
  }

  @Test("chord codes are disjoint from the modifier keycodes and the mouse namespace")
  func chordCodesAreDisjoint() {
    let chordCodes = Set(
      (1...TriggerBinding.ChordModifiers.all.rawValue).map {
        TriggerBinding.chord(
          keyCode: 2, modifiers: TriggerBinding.ChordModifiers(rawValue: $0)
        ).persistedValue
      })
    let modifierCodes = Set(TriggerKey.allCases.map(\.rawValue))
    let mouseCodes = Set(
      (TriggerBinding.minimumMouseButton...TriggerBinding.maximumMouseButton)
        .map { TriggerBinding.mouseButton($0).persistedValue })
    #expect(chordCodes.isDisjoint(with: modifierCodes))
    #expect(chordCodes.isDisjoint(with: mouseCodes))
  }

  @Test("a chord with no modifiers or a modifier as its key is refused at capture")
  func chordCapturePolicy() {
    #expect(TriggerBinding.chordBinding(forKeyCode: 2, modifiers: []) == .failure(.bareKey))
    #expect(
      TriggerBinding.chordBinding(forKeyCode: 96, modifiers: []) == .failure(.bareKey))  // bare F5
    // A modifier keycode can't be a chord's key half, even with modifiers held.
    #expect(
      TriggerBinding.chordBinding(forKeyCode: 54, modifiers: [.control]) == .failure(.modifierOnly))
    #expect(
      TriggerBinding.chordBinding(forKeyCode: 63, modifiers: [.control]) == .failure(.modifierOnly))
    // The everyday case succeeds.
    #expect(
      TriggerBinding.chordBinding(forKeyCode: 2, modifiers: [.control, .option])
        == .success(.chord(keyCode: 2, modifiers: [.control, .option])))
    // A modifier + F-key chord is fine — it's the *bare* F-key that was refused.
    #expect(
      TriggerBinding.chordBinding(forKeyCode: 96, modifiers: [.option])
        == .success(.chord(keyCode: 96, modifiers: [.option])))
  }

  @Test("system-reserved chords are refused")
  func reservedChordsRefused() {
    // Each would fire its system action underneath the dictation, because the
    // tap swallows nothing.
    #expect(TriggerBinding.chordBinding(forKeyCode: 12, modifiers: [.command]) == .failure(.reserved))  // ⌘Q
    #expect(TriggerBinding.chordBinding(forKeyCode: 13, modifiers: [.command]) == .failure(.reserved))  // ⌘W
    #expect(TriggerBinding.chordBinding(forKeyCode: 48, modifiers: [.command]) == .failure(.reserved))  // ⌘⇥
    #expect(TriggerBinding.chordBinding(forKeyCode: 49, modifiers: [.command]) == .failure(.reserved))  // ⌘Space
    #expect(
      TriggerBinding.chordBinding(forKeyCode: 12, modifiers: [.control, .command])
        == .failure(.reserved))  // ⌃⌘Q
    // Adding a modifier makes it the user's own shortcut again, not the system's.
    #expect(
      TriggerBinding.chordBinding(forKeyCode: 12, modifiers: [.option, .command])
        == .success(.chord(keyCode: 12, modifiers: [.option, .command])))
  }

  @Test("a structurally invalid packed chord falls back to right ⌘")
  func invalidChordsFallBack() {
    let base = TriggerBinding.chordCodeBase
    // No modifier bits: a bare key was never bindable, so a stored one is garbage.
    #expect(TriggerBinding.fromPersisted(base | 2) == .modifier(.rightCommand))
    // A modifier keycode as the key half.
    #expect(
      TriggerBinding.fromPersisted(TriggerBinding.packedChord(keyCode: 54, modifiers: [.control]))
        == .modifier(.rightCommand))
    // Bits set above the four modifiers.
    #expect(
      TriggerBinding.fromPersisted(base | (0x10 << TriggerBinding.chordModifierShift) | 2)
        == .modifier(.rightCommand))
  }

  @Test("chord labels render as macOS glyph sequences in canonical order")
  func chordLabels() {
    // ⌃⌥⇧⌘ is Apple's order regardless of the order the user pressed them in.
    #expect(TriggerBinding.chord(keyCode: 2, modifiers: [.option, .control]).label == "⌃⌥D")
    #expect(
      TriggerBinding.chord(keyCode: 2, modifiers: [.command, .shift, .option, .control]).label
        == "⌃⌥⇧⌘D")
    #expect(TriggerBinding.chord(keyCode: 49, modifiers: [.control]).label == "⌃Space")
    #expect(TriggerBinding.chord(keyCode: 96, modifiers: [.option]).label == "⌥F5")
    #expect(TriggerBinding.chord(keyCode: 36, modifiers: [.command, .shift]).label == "⇧⌘↩")
    // An unmapped keycode still names itself rather than rendering as nothing.
    #expect(TriggerBinding.chord(keyCode: 200, modifiers: [.control]).label == "⌃key 200")
  }

  @Test("a bare keyboard keycode falls back to right ⌘ — a key alone isn't bindable")
  func keyboardKeycodesFallBack() {
    // Only a *chord* can carry a keyboard key, and chords live in their own
    // namespace, so a bare keycode in the slot is garbage (this includes the
    // F-keys an earlier revision of the Custom option stored raw).
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
    // Raw button numbers are 0-based (0 left, 1 right, 2 wheel/middle); the
    // display name is 1-based the way mice are numbered for users. So the stored
    // 2 shows as "Mouse 3" and IS the middle click — this pins that off-by-one
    // deliberately, because a label that disagrees with the raw number is
    // exactly what would mislead someone reading the log or the code.
    #expect(TriggerBinding.mouseButton(2).label == "Mouse 3")
    #expect(TriggerBinding.mouseButton(3).label == "Mouse 4")
    #expect(TriggerBinding.mouseButton(31).label == "Mouse 32")
  }

  /// The tap is listen-only, so some bindings reach the focused app as well as
  /// Blurt. The UI says so for exactly the two families where it bites.
  @Test("the wheel click and every chord carry a pass-through caution; nothing else does")
  func passThroughNotes() throws {
    #expect(TriggerBinding.modifier(.rightCommand).passThroughNote == nil)
    #expect(TriggerBinding.modifier(.rightOption).passThroughNote == nil)
    // Button 2 is the wheel click, which browsers and terminals act on.
    let wheel = try #require(TriggerBinding.mouseButton(2).passThroughNote)
    #expect(wheel.contains("wheel click"))
    // Side buttons: almost nothing claims them, so no caution.
    #expect(TriggerBinding.mouseButton(3).passThroughNote == nil)
    #expect(TriggerBinding.mouseButton(4).passThroughNote == nil)
    // A chord names itself in its caution, since the app that owns it varies.
    let chord = TriggerBinding.chord(keyCode: 2, modifiers: [.control, .option])
    #expect(chord.passThroughNote?.contains("⌃⌥D") == true)
  }
}
