import CoreGraphics
import Testing

@testable import BlurtEngine

/// Decode-level fixtures: **real `CGEvent`s**, constructed with the same
/// initializers macOS uses to deliver input, fed through the engine's
/// tap-delivery reduction (`DictationEventDecoder.routerEvent`) and asserted
/// against the router events they must produce. This is the layer the pure
/// router suites can't cover — that a genuine `otherMouseDown` for button 3
/// actually carries `mouseEventButtonNumber == 3` into `.mouseDown(button: 3)`.
///
/// The fixtures are data (button/keycode, event type, expected router event) so
/// captures from real hardware — a mouse whose extra buttons arrive as
/// something unexpected — can be appended as new rows rather than new code.
///
/// Constructing events posts nothing and needs no event tap, no Accessibility
/// grant, and no key window, so this runs on CI. If a headless runner ever
/// proves otherwise, gate the suites with `.enabled(if:)` on an environment
/// flag the way `MicCaptureLevelsTests` gates on `BLURT_LIVE_AUDIO_TESTS` —
/// never by creating a real `CGEventTap` here.
@Suite("DictationEventDecoder")
struct DictationEventDecoderTests {
  /// Right ⌘'s device-dependent bit (`TriggerKey.rightCommand.deviceModifierMask`),
  /// the flag a modifier binding hands the decoder.
  private static let rightCommandFlag = CGEventFlags(
    rawValue: TriggerKey.rightCommand.deviceModifierMask)

  /// One replayed mouse delivery: the button and type the event is built from,
  /// and the router event the decoder must produce. Append rows here for new
  /// hardware captures.
  struct MouseFixture: Sendable {
    let button: Int
    let type: CGEventType
    let expected: DictationKeyRouter.Event?
  }

  static let mouseFixtures: [MouseFixture] = [
    // The bindable range, down and up: middle ("Mouse 3"), the MX-style thumb
    // buttons ("Mouse 4"/"Mouse 5"), and the edges of what CGEvent can report.
    MouseFixture(button: 2, type: .otherMouseDown, expected: .mouseDown(button: 2)),
    MouseFixture(button: 2, type: .otherMouseUp, expected: .mouseUp(button: 2)),
    MouseFixture(button: 3, type: .otherMouseDown, expected: .mouseDown(button: 3)),
    MouseFixture(button: 3, type: .otherMouseUp, expected: .mouseUp(button: 3)),
    MouseFixture(button: 4, type: .otherMouseDown, expected: .mouseDown(button: 4)),
    MouseFixture(button: 4, type: .otherMouseUp, expected: .mouseUp(button: 4)),
    MouseFixture(button: 31, type: .otherMouseDown, expected: .mouseDown(button: 31)),
    MouseFixture(button: 31, type: .otherMouseUp, expected: .mouseUp(button: 31)),
    // Left/right clicks arrive as their own event types, which the tap's mask
    // doesn't even include — the decoder must ignore them, not misread them as
    // extra buttons.
    MouseFixture(button: 0, type: .leftMouseDown, expected: nil),
    MouseFixture(button: 0, type: .leftMouseUp, expected: nil),
    MouseFixture(button: 1, type: .rightMouseDown, expected: nil),
    MouseFixture(button: 1, type: .rightMouseUp, expected: nil),
  ]

  private static func mouseEvent(type: CGEventType, button: Int) throws -> CGEvent {
    let cgButton = try #require(CGMouseButton(rawValue: UInt32(button)))
    return try #require(
      CGEvent(
        mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: cgButton))
  }

  @Test("a real mouse CGEvent decodes to the expected router event", arguments: mouseFixtures)
  func decodesMouseEvents(fixture: MouseFixture) throws {
    let event = try Self.mouseEvent(type: fixture.type, button: fixture.button)
    let decoded = DictationEventDecoder.routerEvent(
      type: fixture.type, event: event, triggerFlag: [])
    #expect(decoded == fixture.expected)
  }

  @Test("a real keyDown CGEvent decodes to the combo probe with its keycode")
  func decodesKeyDown() throws {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))  // C
    event.flags = []
    let decoded = DictationEventDecoder.routerEvent(
      type: .keyDown, event: event, triggerFlag: Self.rightCommandFlag)
    #expect(decoded == .keyDown(keyCode: 8, modifiers: []))
  }

  @Test("a real keyUp CGEvent decodes to the chord's trigger-up")
  func decodesKeyUp() throws {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false))
    let decoded = DictationEventDecoder.routerEvent(
      type: .keyUp, event: event, triggerFlag: Self.rightCommandFlag)
    #expect(decoded == .keyUp(keyCode: 8))
  }

  // MARK: - Chord decode

  /// One replayed chord keyDown: the flags the event carries and the modifier set
  /// they must decode to. Rows are data, so a keyboard or driver that reports
  /// flags oddly can be added as a fixture rather than as new code.
  struct ChordFixture: Sendable {
    let flags: CGEventFlags
    let expected: TriggerBinding.ChordModifiers
  }

  static let chordFixtures: [ChordFixture] = [
    ChordFixture(flags: [], expected: []),
    ChordFixture(flags: [.maskControl], expected: [.control]),
    ChordFixture(flags: [.maskAlternate], expected: [.option]),
    ChordFixture(flags: [.maskShift], expected: [.shift]),
    ChordFixture(flags: [.maskCommand], expected: [.command]),
    // The everyday ⌃⌥D shape, and the full house.
    ChordFixture(flags: [.maskControl, .maskAlternate], expected: [.control, .option]),
    ChordFixture(
      flags: [.maskControl, .maskAlternate, .maskShift, .maskCommand],
      expected: [.control, .option, .shift, .command]),
    // The device-dependent side bits ride along with the generic mask on a real
    // press; a chord is side-agnostic, so they must not change the decode.
    ChordFixture(
      flags: [.maskControl, CGEventFlags(rawValue: 0x2000)], expected: [.control]),
    // Caps Lock and fn are deliberately not chord modifiers.
    ChordFixture(flags: [.maskAlphaShift], expected: []),
    ChordFixture(flags: [.maskSecondaryFn], expected: []),
    ChordFixture(flags: [.maskAlphaShift, .maskCommand], expected: [.command]),
  ]

  @Test("a chord keyDown decodes its modifier set from the event's flags", arguments: chordFixtures)
  func decodesChordModifiers(fixture: ChordFixture) throws {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 2, keyDown: true))  // D
    event.flags = fixture.flags
    let decoded = DictationEventDecoder.routerEvent(
      type: .keyDown, event: event, triggerFlag: [])
    #expect(decoded == .keyDown(keyCode: 2, modifiers: fixture.expected))
  }

  @Test("an autorepeat keyDown decodes to nothing — a repeat is not an edge")
  func dropsAutorepeatKeyDown() throws {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 2, keyDown: true))
    event.flags = [.maskControl, .maskAlternate]
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    #expect(DictationEventDecoder.routerEvent(type: .keyDown, event: event, triggerFlag: []) == nil)

    // The same event without the repeat flag is the real trigger-down.
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    #expect(
      DictationEventDecoder.routerEvent(type: .keyDown, event: event, triggerFlag: [])
        == .keyDown(keyCode: 2, modifiers: [.control, .option]))
  }

  @Test("a partial-modifier release decodes to the flags event a chord ends on")
  func decodesPartialModifierRelease() throws {
    // ⌃⌥ held, then ⌃ released: the delivery reports ⌥ still down, which is what
    // tells the router the chord is no longer complete.
    let event = try #require(
      CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(59), keyDown: false))  // left ⌃
    event.type = .flagsChanged
    event.flags = [.maskAlternate]
    let decoded = DictationEventDecoder.routerEvent(
      type: .flagsChanged, event: event, triggerFlag: [])
    #expect(decoded == .flagsChanged(keyCode: 59, triggerFlagIsOn: false, modifiers: [.option]))
  }

  @Test("a flagsChanged CGEvent decodes the keycode and the trigger flag, set and cleared")
  func decodesFlagsChanged() throws {
    let event = try #require(
      CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(54), keyDown: true))  // right ⌘
    event.type = .flagsChanged
    event.flags = [.maskCommand, Self.rightCommandFlag]
    let down = DictationEventDecoder.routerEvent(
      type: .flagsChanged, event: event, triggerFlag: Self.rightCommandFlag)
    #expect(down == .flagsChanged(keyCode: 54, triggerFlagIsOn: true, modifiers: [.command]))

    event.flags = []
    let up = DictationEventDecoder.routerEvent(
      type: .flagsChanged, event: event, triggerFlag: Self.rightCommandFlag)
    #expect(up == .flagsChanged(keyCode: 54, triggerFlagIsOn: false, modifiers: []))
  }

  @Test("a flagsChanged delivery for another modifier still reports its own keycode")
  func decodesOtherModifiersFlagsChanged() throws {
    // Left ⌘ going down while right ⌘ is bound: the generic command bit is set,
    // the right-side device bit is not — the decoder must report exactly that,
    // and the router's keycode relevance filter does the ignoring.
    let event = try #require(
      CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(55), keyDown: true))  // left ⌘
    event.type = .flagsChanged
    event.flags = [.maskCommand]
    let decoded = DictationEventDecoder.routerEvent(
      type: .flagsChanged, event: event, triggerFlag: Self.rightCommandFlag)
    #expect(decoded == .flagsChanged(keyCode: 55, triggerFlagIsOn: false, modifiers: [.command]))
  }

  @Test("event types outside the tap's interest decode to nothing")
  func ignoresIrrelevantTypes() throws {
    let event = try Self.mouseEvent(type: .otherMouseDragged, button: 3)
    let decoded = DictationEventDecoder.routerEvent(
      type: .otherMouseDragged, event: event, triggerFlag: [])
    #expect(decoded == nil)
  }
}
