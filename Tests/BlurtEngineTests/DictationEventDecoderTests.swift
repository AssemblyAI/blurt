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
    let decoded = DictationEventDecoder.routerEvent(
      type: .keyDown, event: event, triggerFlag: Self.rightCommandFlag)
    #expect(decoded == .keyDown(keyCode: 8))
  }

  @Test("a keyUp CGEvent decodes to nothing — no binding consumes key-ups")
  func ignoresKeyUp() throws {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false))
    let decoded = DictationEventDecoder.routerEvent(
      type: .keyUp, event: event, triggerFlag: Self.rightCommandFlag)
    #expect(decoded == nil)
  }

  @Test("a flagsChanged CGEvent decodes the keycode and the trigger flag, set and cleared")
  func decodesFlagsChanged() throws {
    let event = try #require(
      CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(54), keyDown: true))  // right ⌘
    event.type = .flagsChanged
    event.flags = [.maskCommand, Self.rightCommandFlag]
    let down = DictationEventDecoder.routerEvent(
      type: .flagsChanged, event: event, triggerFlag: Self.rightCommandFlag)
    #expect(down == .flagsChanged(keyCode: 54, triggerFlagIsOn: true))

    event.flags = []
    let up = DictationEventDecoder.routerEvent(
      type: .flagsChanged, event: event, triggerFlag: Self.rightCommandFlag)
    #expect(up == .flagsChanged(keyCode: 54, triggerFlagIsOn: false))
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
    #expect(decoded == .flagsChanged(keyCode: 55, triggerFlagIsOn: false))
  }

  @Test("event types outside the tap's interest decode to nothing")
  func ignoresIrrelevantTypes() throws {
    let event = try Self.mouseEvent(type: .otherMouseDragged, button: 3)
    let decoded = DictationEventDecoder.routerEvent(
      type: .otherMouseDragged, event: event, triggerFlag: [])
    #expect(decoded == nil)
  }
}
