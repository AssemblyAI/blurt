import Testing

@testable import BlurtEngine

@Suite("InspectorHotkey chord matching")
struct InspectorHotkeyTests {
  // Generic CGEventFlags bits: control 0x40000, option 0x80000, command 0x100000.
  private let ctrlOptCmd: UInt64 = 0x40000 | 0x80000 | 0x100000
  private let pKey = 35

  @Test("matches control+option+command+P")
  func matchesChord() {
    #expect(InspectorHotkey.matches(keyCode: pKey, flags: ctrlOptCmd))
  }

  @Test("matches even with extra modifiers held (shift, fn)")
  func matchesWithExtraModifiers() {
    let withShiftAndFn = ctrlOptCmd | 0x20000 | 0x800000
    #expect(InspectorHotkey.matches(keyCode: pKey, flags: withShiftAndFn))
  }

  @Test("does not match the wrong key")
  func rejectsWrongKey() {
    #expect(!InspectorHotkey.matches(keyCode: 8 /* C */, flags: ctrlOptCmd))
  }

  @Test("does not match when a required modifier is missing")
  func rejectsMissingModifier() {
    #expect(!InspectorHotkey.matches(keyCode: pKey, flags: 0x80000 | 0x100000))  // no control
    #expect(!InspectorHotkey.matches(keyCode: pKey, flags: 0x40000 | 0x100000))  // no option
    #expect(!InspectorHotkey.matches(keyCode: pKey, flags: 0x40000 | 0x80000))  // no command
  }

  @Test("does not match a bare P keypress")
  func rejectsBareKey() {
    #expect(!InspectorHotkey.matches(keyCode: pKey, flags: 0))
  }
}
