/// What the user bound as the single dictation trigger: a lone modifier key
/// (the default family — see `TriggerKey`) or an extra mouse button. One
/// binding, one physical control — never a chord.
///
/// Every binding encodes into the single persisted `Int` slot `TriggerKeyStore`
/// has always used (`BlurtTriggerKeyCode`), so existing installs migrate with no
/// data change and `@AppStorage` views keep observing one key:
///
/// - A modifier stores its virtual keycode (54/61/63), exactly as before.
/// - A mouse button stores `mouseButtonCodeBase + buttonNumber`, a namespace far
///   above any virtual keycode (keycodes are 16-bit), so the two families can't
///   collide (`TriggerBindingTests` pins that).
///
/// The curation is deliberate policy, not a parsing limit: the event tap is
/// listen-only and swallows nothing, so a bound keyboard key would type into
/// the focused app on every dictation (keyboard keys beyond the curated
/// modifiers are out of scope for Custom by maintainer decision), and the
/// left/right mouse buttons are how the user operates the machine. Extra
/// buttons (Mouse 3 and up) click nothing.
public enum TriggerBinding: Sendable, Hashable {
  /// A lone modifier (right ⌘, right ⌥, `fn`) — the original trigger family,
  /// driven by `flagsChanged` events.
  case modifier(TriggerKey)
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

  /// Decodes the persisted slot into a binding, falling back to the right-⌘
  /// modifier for anything unrecognized — an unset slot (0), a keycode from a
  /// removed option, or a mouse code outside the bindable range. The single
  /// decode-with-default rule shared by `TriggerKeyStore` and the `@AppStorage`
  /// views that read the raw slot directly (so they re-render live on a
  /// Settings change).
  public static func fromPersisted(_ code: Int) -> TriggerBinding {
    if let key = TriggerKey(rawValue: code) { return .modifier(key) }
    if let binding = mouseButtonBinding(forButton: code - mouseButtonCodeBase) { return binding }
    return .modifier(.rightCommand)
  }

  /// The binding for a captured mouse button number, or nil when that button
  /// isn't bindable (0/1 are the left/right click; past 31 `CGEvent` can't
  /// report it). The capture UI's single policy check, so "which buttons are
  /// allowed" is engine logic with tests rather than a view's private list.
  public static func mouseButtonBinding(forButton button: Int) -> TriggerBinding? {
    (minimumMouseButton...maximumMouseButton).contains(button) ? .mouseButton(button) : nil
  }

  /// The value stored in the persisted slot; `fromPersisted` round-trips it.
  /// Internal: `TriggerKeyStore` owns the write, and hosts go through it.
  var persistedValue: Int {
    switch self {
    case .modifier(let key): return key.rawValue
    case .mouseButton(let button): return Self.mouseButtonCodeBase + button
    }
  }

  /// Inline sentence form, e.g. "Tap or hold Mouse 4 to dictate". Mouse buttons
  /// use the 1-based numbering macOS and pointing-device vendors present to
  /// users (button number 3 is "Mouse 4").
  public var label: String {
    switch self {
    case .modifier(let key): return key.label
    case .mouseButton(let button): return "Mouse \(button + 1)"
    }
  }
}
