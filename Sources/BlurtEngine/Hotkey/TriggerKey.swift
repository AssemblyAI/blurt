/// A lone momentary modifier key usable as the single dictation trigger. The raw
/// value is the macOS virtual key code, so `TriggerKey(rawValue:)` decodes a
/// persisted keycode directly. Curated to right-side modifiers, which are rarely
/// used in app shortcuts, so a solo press maps cleanly to "dictate", plus `fn` —
/// whose own macOS action `GlobeKeyOverride` turns off while it's bound.
public enum TriggerKey: Int, CaseIterable, Sendable, Hashable {
  case rightCommand = 54
  case rightOption = 61
  case function = 63
  // The left-hand keys: off by default, except left ⌥, which reads the selection
  // aloud (`TriggerKeyBindings.defaultChoice`). Any key can take any action.
  case leftCommand = 55
  case leftOption = 58
  case leftControl = 59

  public var keyCode: Int { rawValue }

  /// Decodes a persisted keycode into a `TriggerKey`, falling back to right ⌘
  /// when the value isn't one of the curated options. The single decode-with-
  /// default rule shared by `TriggerKeyStore` and the `@AppStorage` views that
  /// read the raw keycode directly (so they re-render live on a Settings change).
  public static func fromPersisted(_ code: Int) -> TriggerKey {
    TriggerKey(rawValue: code) ?? .rightCommand
  }

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
  /// unambiguous. `fn` has no left/right twin, so its secondary-fn bit already
  /// names one physical key.
  public var deviceModifierMask: UInt64 {
    switch self {
    case .rightCommand: return 0x10  // NX_DEVICERCMDKEYMASK
    case .rightOption: return 0x40  // NX_DEVICERALTKEYMASK
    case .function: return 0x80_0000  // kCGEventFlagMaskSecondaryFn
    case .leftCommand: return 0x08  // NX_DEVICELCMDKEYMASK
    case .leftOption: return 0x20  // NX_DEVICELALTKEYMASK
    case .leftControl: return 0x01  // NX_DEVICELCTLKEYMASK
    }
  }

  /// Inline sentence form, e.g. "Tap or hold right ⌘ to dictate".
  public var label: String {
    switch self {
    case .rightCommand: return "right ⌘"
    case .rightOption: return "right ⌥"
    case .function: return "fn"
    case .leftCommand: return "left ⌘"
    case .leftOption: return "left ⌥"
    case .leftControl: return "left ⌃"
    }
  }

  /// Spelled-out form with the symbol in parentheses, e.g.
  /// "Right Command (⌘)" — the ready screen's readout bolds this inline, where
  /// the bare symbol alone assumes the reader already knows the glyph.
  public var fullName: String {
    switch self {
    case .rightCommand: return "Right Command (⌘)"
    case .rightOption: return "Right Option (⌥)"
    case .function: return "Function (fn)"
    case .leftCommand: return "Left Command (⌘)"
    case .leftOption: return "Left Option (⌥)"
    case .leftControl: return "Left Control (⌃)"
    }
  }
}
