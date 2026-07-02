/// The undocumented Prompt Inspector chord: ⌃⌥⌘P.
///
/// A pure matcher kept in the engine (CoreGraphics-free, so unit-testable) that
/// `DictationKeyTap` calls with primitive values pulled off a `CGEvent`. Mirrors
/// how `DictationKeyGate` owns the per-event decision while the tap only bridges.
///
/// The flag bits are the *generic* CGEventFlags masks (side-agnostic), so the
/// chord fires regardless of which control/option/command key is held. Extra
/// modifiers (shift, fn) don't block the match — this is a debug affordance, not
/// a user-facing shortcut that must be exact.
public enum InspectorHotkey {
  /// Virtual key code for the "P" key (mnemonic: Prompt).
  public static let keyCode = 35

  /// control | option | command (generic CGEventFlags mask bits).
  static let requiredFlags: UInt64 = 0x40000 | 0x80000 | 0x100000

  /// Whether a key-down of `keyCode` with `flags` set is the inspector chord.
  public static func matches(keyCode: Int, flags: UInt64) -> Bool {
    keyCode == Self.keyCode && (flags & requiredFlags) == requiredFlags
  }
}
