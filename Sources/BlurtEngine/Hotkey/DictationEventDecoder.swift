import CoreGraphics

/// Reduces a `CGEventTap` delivery to `DictationKeyRouter`'s CoreGraphics-free
/// event shape — the one deliberately CoreGraphics-typed piece of the hotkey
/// engine, split out of the app's tap shim so it can be exercised with *real*
/// `CGEvent` fixtures (`DictationEventDecoderTests` constructs events with
/// `CGEvent(mouseEventSource:…)`/`CGEvent(keyboardEventSource:…)` and asserts
/// the router events they decode to). The router itself stays CoreGraphics-free
/// on purpose; this is the boundary where `CGEvent` ends.
///
/// The type is passed alongside the event (rather than read off it) because
/// that is what a `CGEventTapCallBack` receives — the two can genuinely differ
/// during tap-disable deliveries, and the callback's `type` is the authority.
public enum DictationEventDecoder {
  /// The router event a tap delivery reduces to, or nil for event types the
  /// trigger doesn't care about. `triggerFlag` is the bound modifier's
  /// device-dependent `CGEventFlags` bit, and is **empty under a chord or mouse
  /// binding** — where the resulting `triggerFlagIsOn` is meaningless and must
  /// not be read: `CGEventFlags.contains([])` is vacuously true, so an empty
  /// trigger flag reports "on" for every delivery. The router honors that (only
  /// `handleForModifier` looks at the field); `DictationEventDecoderTests` pins
  /// it so it can't be mistaken for a bug later.
  public static func routerEvent(
    type: CGEventType, event: CGEvent, triggerFlag: CGEventFlags
  ) -> DictationKeyRouter.Event? {
    switch type {
    case .flagsChanged:
      return .flagsChanged(
        keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
        triggerFlagIsOn: event.flags.contains(triggerFlag),
        modifiers: modifiers(from: event.flags))
    case .keyDown:
      // Autorepeat is not an edge: a held chord key repeats at the system rate,
      // and every repeat would otherwise walk the router's dedup. Dropped here so
      // the repeat storm never reaches the engine at all.
      guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
      return .keyDown(
        keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
        modifiers: modifiers(from: event.flags))
    case .keyUp:
      return .keyUp(keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)))
    case .otherMouseDown:
      return .mouseDown(button: Int(event.getIntegerValueField(.mouseEventButtonNumber)))
    case .otherMouseUp:
      return .mouseUp(button: Int(event.getIntegerValueField(.mouseEventButtonNumber)))
    default:
      return nil
    }
  }

  /// The side-agnostic chord modifier set a `CGEvent`'s flags carry. Reads the
  /// **generic** masks (`maskControl` etc.), not the per-side device bits
  /// `TriggerKey` uses: a chord is a shortcut, so ⌃ is ⌃ whichever one is held.
  /// Caps Lock and `fn` are deliberately not chord modifiers — Caps Lock is a
  /// latch rather than a held key, and `fn` is macOS's own.
  public static func modifiers(from flags: CGEventFlags) -> TriggerBinding.ChordModifiers {
    var modifiers: TriggerBinding.ChordModifiers = []
    if flags.contains(.maskControl) { modifiers.insert(.control) }
    if flags.contains(.maskAlternate) { modifiers.insert(.option) }
    if flags.contains(.maskShift) { modifiers.insert(.shift) }
    if flags.contains(.maskCommand) { modifiers.insert(.command) }
    return modifiers
  }
}
