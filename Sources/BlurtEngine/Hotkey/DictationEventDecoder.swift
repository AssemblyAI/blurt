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
  /// device-dependent `CGEventFlags` bit (empty under a mouse binding, where
  /// the router ignores `flagsChanged` events entirely).
  public static func routerEvent(
    type: CGEventType, event: CGEvent, triggerFlag: CGEventFlags
  ) -> DictationKeyRouter.Event? {
    switch type {
    case .flagsChanged:
      return .flagsChanged(
        keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
        triggerFlagIsOn: event.flags.contains(triggerFlag))
    case .keyDown:
      return .keyDown(keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)))
    case .otherMouseDown:
      return .mouseDown(button: Int(event.getIntegerValueField(.mouseEventButtonNumber)))
    case .otherMouseUp:
      return .mouseUp(button: Int(event.getIntegerValueField(.mouseEventButtonNumber)))
    default:
      return nil
    }
  }
}
