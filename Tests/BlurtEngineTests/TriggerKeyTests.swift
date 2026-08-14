import Testing

@testable import BlurtEngine

@Suite("TriggerKey")
struct TriggerKeyTests {
  @Test("keyCode matches the macOS virtual keycode")
  func keyCodes() {
    #expect(TriggerKey.rightCommand.keyCode == 54)
    #expect(TriggerKey.rightOption.keyCode == 61)
    #expect(TriggerKey.function.keyCode == 63)
  }

  @Test("every case has a non-empty label")
  func labels() {
    for key in TriggerKey.allCases {
      #expect(!key.label.isEmpty)
    }
    #expect(TriggerKey.rightCommand.label == "right ⌘")
  }

  @Test("raw value round-trips through keyCode")
  func roundTrip() {
    #expect(TriggerKey(rawValue: 54) == .rightCommand)
    #expect(TriggerKey(rawValue: 999) == nil)
  }

  @Test("removed options (right ⌃, Caps Lock) are not modifiers")
  func removedOptionsDoNotDecode() {
    // right ⌃ (keycode 62) and Caps Lock (57) were dropped as options; the
    // persisted-slot fallback they decode to is `TriggerBinding.fromPersisted`'s
    // job (see `TriggerBindingTests.removedOptionsFallBack`).
    #expect(TriggerKey(rawValue: 62) == nil)
    #expect(TriggerKey(rawValue: 57) == nil)
  }

  // The hotkey tap reads the *device-dependent* modifier bit (which physical
  // side toggled) rather than the generic command/option/control mask, which is
  // shared by both the left and right keys. Reading the shared mask can't tell a
  // right-⌘ release from "right released but left still held," which desyncs the
  // tap's down/up tracking on keyboards with both keys in play.
  @Test("deviceModifierMask is the right-side NX device bit")
  func deviceMasks() {
    #expect(TriggerKey.rightCommand.deviceModifierMask == 0x10)  // NX_DEVICERCMDKEYMASK
    #expect(TriggerKey.rightOption.deviceModifierMask == 0x40)  // NX_DEVICERALTKEYMASK
    #expect(TriggerKey.function.deviceModifierMask == 0x80_0000)  // kCGEventFlagMaskSecondaryFn
  }

  @Test("right-⌘ mask does not collide with the left-⌘ or generic ⌘ bit")
  func rightCommandIsDistinctFromLeft() {
    let leftCommandBit: UInt64 = 0x8  // NX_DEVICELCMDKEYMASK
    let genericCommandMask: UInt64 = 0x10_0000  // kCGEventFlagMaskCommand
    let right = TriggerKey.rightCommand.deviceModifierMask
    #expect(right & leftCommandBit == 0)
    #expect(right & genericCommandMask == 0)
  }

  @Test("each trigger maps to exactly one distinct flag bit")
  func masksAreSingleBitAndUnique() {
    var seen = Set<UInt64>()
    for key in TriggerKey.allCases {
      let mask = key.deviceModifierMask
      #expect(mask.nonzeroBitCount == 1, "\(key) mask should be a single bit")
      #expect(seen.insert(mask).inserted, "\(key) mask collides with another trigger")
    }
  }
}
