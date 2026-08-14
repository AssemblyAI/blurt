/// A lone momentary modifier key usable as the dictation trigger — the default
/// family of `TriggerBinding`, which owns decoding the persisted slot
/// (`TriggerBinding.fromPersisted`). The raw value is the macOS virtual key
/// code, so `TriggerKey(rawValue:)` decodes a persisted keycode directly.
/// Curated to right-side modifiers (rarely used in app shortcuts, so a solo
/// press maps cleanly to "dictate") and `fn`.
public enum TriggerKey: Int, CaseIterable, Sendable, Hashable {
  case rightCommand = 54
  case rightOption = 61
  case function = 63

  public var keyCode: Int { rawValue }

  /// The **device-dependent** modifier flag bit this key toggles, as a raw
  /// `CGEventFlags`/IOKit value (the app wraps it in `CGEventFlags(rawValue:)`).
  ///
  /// The hotkey tap reads this bit — not the generic `kCGEventFlagMaskCommand`
  /// (`0x10_0000`) etc. — to decide whether the bound key is down. The generic
  /// mask is set by *both* the left and right key, so reading it can't tell a
  /// right-⌘ release from "right released, left still held," which desyncs the
  /// tap's down/up tracking on keyboards where both keys are in play (a leading
  /// suspect for the duplicate-paste reports on third-party keyboards). The
  /// device bit names exactly one physical side, so the bound key's own state is
  /// unambiguous. `fn` has no left/right split, so it uses the secondary-fn bit.
  public var deviceModifierMask: UInt64 {
    switch self {
    case .rightCommand: return 0x10  // NX_DEVICERCMDKEYMASK
    case .rightOption: return 0x40  // NX_DEVICERALTKEYMASK
    case .function: return 0x80_0000  // kCGEventFlagMaskSecondaryFn
    }
  }

  /// Inline sentence form, e.g. "Tap or hold right ⌘ to dictate".
  public var label: String {
    switch self {
    case .rightCommand: return "right ⌘"
    case .rightOption: return "right ⌥"
    case .function: return "fn"
    }
  }
}
