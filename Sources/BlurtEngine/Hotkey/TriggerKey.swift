/// A lone momentary modifier key usable as the single dictation trigger. The raw
/// value is the macOS virtual key code, so `TriggerKey(rawValue:)` decodes a
/// persisted keycode directly. Curated to right-side modifiers (rarely used in
/// app shortcuts, so a solo press maps cleanly to "dictate") and `fn`.
public enum TriggerKey: Int, CaseIterable, Sendable, Hashable {
  case rightCommand = 54
  case rightOption = 61
  case function = 63

  public var keyCode: Int { rawValue }

  /// Decodes a persisted keycode into a `TriggerKey`, falling back to right ⌘
  /// when the value isn't one of the curated options. The single decode-with-
  /// default rule shared by `TriggerKeyStore` and the `@AppStorage` views that
  /// read the raw keycode directly (so they re-render live on a Settings change).
  public static func fromPersisted(_ code: Int) -> TriggerKey {
    TriggerKey(rawValue: code) ?? .rightCommand
  }

  /// The modifier flag bit this key toggles, as a raw `CGEventFlags`/IOKit value
  /// (the app wraps it in `CGEventFlags(rawValue:)`).
  ///
  /// The hotkey tap reads this bit — not the generic `kCGEventFlagMaskCommand`
  /// (`0x10_0000`) etc. — to decide whether the bound key is down. The generic
  /// mask is set by *both* the left and right key, so reading it can't tell a
  /// right-⌘ release from "right released, left still held," which desyncs the
  /// tap's down/up tracking on keyboards where both keys are in play (a leading
  /// suspect for the duplicate-paste reports on third-party keyboards). The
  /// **device-dependent** `NX_DEVICE*` bit names exactly one physical side, so
  /// the bound key's own state is unambiguous.
  ///
  /// `fn` is the one option without such a bit — there is no `NX_DEVICE*` split
  /// for it, only the shared `kCGEventFlagMaskSecondaryFn` — and that is why it
  /// was dropped as an option once (#146) before being restored. Sharing is
  /// harmless here in a way it isn't for ⌘/⌥: the bit is shared only among `fn`
  /// keys, and every one of them *is* the bound key, so the tracking stays
  /// coherent rather than desyncing. With two keyboards attached, the bit reads
  /// down from the first `fn` press to the last `fn` release, which is exactly
  /// what "the trigger is held" means. The left/right ambiguity has no analogue.
  ///
  /// The remaining `fn` caveat is macOS's own, not the tap's: the tap is
  /// listen-only and swallows nothing, so whatever System Settings ▸ Keyboard
  /// has under "Press 🌐 key to" still fires alongside dictation. Users who bind
  /// `fn` will want that set to "Do Nothing".
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

  /// Spelled-out form with the symbol in parentheses, e.g.
  /// "Right Command (⌘)" — the ready screen's readout bolds this inline, where
  /// the bare symbol alone assumes the reader already knows the glyph.
  public var fullName: String {
    switch self {
    case .rightCommand: return "Right Command (⌘)"
    case .rightOption: return "Right Option (⌥)"
    case .function: return "Function (fn)"
    }
  }
}
