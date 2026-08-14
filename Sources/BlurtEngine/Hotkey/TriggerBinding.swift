/// What the user bound as the single dictation trigger: a lone modifier key
/// (the default family — see `TriggerKey`), a lone function key (F1–F20), or an
/// extra mouse button. One binding, one physical control — never a chord.
///
/// Every binding encodes into the single persisted `Int` slot `TriggerKeyStore`
/// has always used (`BlurtTriggerKeyCode`), so existing installs migrate with no
/// data change and `@AppStorage` views keep observing one key:
///
/// - A modifier stores its virtual keycode (54/61/63), exactly as before.
/// - A function key stores its virtual keycode raw — the F-key keycodes are
///   disjoint from the three modifier keycodes, so the two families can't
///   collide (`TriggerBindingTests` pins that).
/// - A mouse button stores `mouseButtonCodeBase + buttonNumber`, a namespace far
///   above any virtual keycode (keycodes are 16-bit).
///
/// The curation is deliberate v1 policy, not a parsing limit: the event tap is
/// listen-only and swallows nothing, so a printable key would type into the
/// focused app on every dictation, and the left/right mouse buttons are how the
/// user operates the machine. F-keys and extra buttons (Mouse 3 and up) type
/// nothing and click nothing.
public enum TriggerBinding: Sendable, Hashable {
  /// A lone modifier (right ⌘, right ⌥, `fn`) — the original trigger family,
  /// driven by `flagsChanged` events.
  case modifier(TriggerKey)
  /// A lone function key, by virtual keycode — F1–F20 only in v1. Driven by
  /// `keyDown`/`keyUp` events.
  case key(code: Int)
  /// An extra mouse button, by `CGEvent` button number (2 = the button macOS
  /// calls "Mouse 3", usually the middle button). Driven by
  /// `otherMouseDown`/`otherMouseUp` events.
  case mouseButton(Int)

  /// Where the mouse-button namespace starts in the persisted slot. Virtual
  /// keycodes are 16-bit, so `0x10000 + button` can never collide with one.
  static let mouseButtonCodeBase = 0x10000

  /// The lowest bindable button number: 2 ("Mouse 3"). Buttons 0 and 1 are the
  /// left and right click — binding either would fire dictation on ordinary
  /// mousing, so the recorder refuses them.
  static let minimumMouseButton = 2

  /// The highest bindable button number. `CGEvent` reports up to 32 buttons
  /// (numbers 0–31), so anything past that in the persisted slot is garbage.
  static let maximumMouseButton = 31

  /// The bindable function keys: macOS virtual keycode → display label, F1–F20
  /// (every F-key the HIToolbox virtual-keycode table names).
  static let functionKeyLabels: [Int: String] = [
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
    100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
    107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
  ]

  /// Decodes the persisted slot into a binding, falling back to the right-⌘
  /// modifier for anything unrecognized — an unset slot (0), a keycode from a
  /// removed option, or a mouse code outside the bindable range. The single
  /// decode-with-default rule shared by `TriggerKeyStore` and the `@AppStorage`
  /// views that read the raw slot directly (so they re-render live on a
  /// Settings change).
  public static func fromPersisted(_ code: Int) -> TriggerBinding {
    if let key = TriggerKey(rawValue: code) { return .modifier(key) }
    if let binding = keyBinding(forKeyCode: code) { return binding }
    if let binding = mouseButtonBinding(forButton: code - mouseButtonCodeBase) { return binding }
    return .modifier(.rightCommand)
  }

  /// The binding for a captured keyboard keycode, or nil when that key isn't
  /// bindable (v1 allows F1–F20 only). The capture UI's single policy check, so
  /// "which keys are allowed" is engine logic with tests rather than a view's
  /// private list.
  public static func keyBinding(forKeyCode keyCode: Int) -> TriggerBinding? {
    functionKeyLabels[keyCode] != nil ? .key(code: keyCode) : nil
  }

  /// The binding for a captured mouse button number, or nil when that button
  /// isn't bindable (0/1 are the left/right click; past 31 `CGEvent` can't
  /// report it). Mirror of `keyBinding(forKeyCode:)` for the mouse.
  public static func mouseButtonBinding(forButton button: Int) -> TriggerBinding? {
    (minimumMouseButton...maximumMouseButton).contains(button) ? .mouseButton(button) : nil
  }

  /// The value stored in the persisted slot; `fromPersisted` round-trips it.
  /// Internal: `TriggerKeyStore` owns the write, and hosts go through it.
  var persistedValue: Int {
    switch self {
    case .modifier(let key): return key.rawValue
    case .key(let code): return code
    case .mouseButton(let button): return Self.mouseButtonCodeBase + button
    }
  }

  /// Inline sentence form, e.g. "Tap or hold F5 to dictate". Mouse buttons use
  /// the 1-based numbering macOS and pointing-device vendors present to users
  /// (button number 3 is "Mouse 4").
  public var label: String {
    switch self {
    case .modifier(let key): return key.label
    case .key(let code): return Self.functionKeyLabels[code] ?? "F?"
    case .mouseButton(let button): return "Mouse \(button + 1)"
    }
  }
}
