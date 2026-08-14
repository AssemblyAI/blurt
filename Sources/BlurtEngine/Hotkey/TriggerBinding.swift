/// What the user bound as the dictation trigger: a lone modifier key (the
/// default family — see `TriggerKey`), a **keyboard chord** (modifiers plus one
/// non-modifier key, e.g. ⌃⌥D), or an extra mouse button.
///
/// Every binding encodes into the single persisted `Int` slot `TriggerKeyStore`
/// has always used (`BlurtTriggerKeyCode`), so existing installs migrate with no
/// data change and `@AppStorage` views keep observing one key:
///
/// - A modifier stores its virtual keycode (54/61), exactly as before — and the
///   removed `fn` option's 63 migrates to right ⌥.
/// - A mouse button stores `mouseButtonCodeBase + buttonNumber`.
/// - A chord packs both halves into one tagged value:
///   `chordCodeBase | (modifiers << chordModifierShift) | keyCode` — the keycode
///   in the low byte, the four modifier bits above it. Virtual keycodes are
///   16-bit and the two bases are far above them, so the three families can't
///   collide (`TriggerBindingTests` pins that).
///
/// The curation is policy, not a parsing limit. A **bare** key is refused: the
/// event tap is listen-only and swallows nothing, so it would type into the
/// focused app on every dictation. A chord with modifiers is far less likely to
/// insert text, but it is **not** swallowed either — a chord an app already owns
/// still reaches that app, which is why the recorder also refuses a small set of
/// system-reserved chords and the UI says so plainly. Mouse buttons 0/1 are how
/// the user operates the machine, so only Mouse 3 and up are bindable.
public enum TriggerBinding: Sendable, Hashable {
  /// A lone modifier (right ⌘ or right ⌥) — the original trigger family,
  /// driven by `flagsChanged` events.
  case modifier(TriggerKey)
  /// A keyboard chord: one non-modifier key plus the exact modifier set that
  /// must be held with it. Driven by `keyDown`/`keyUp` plus modifier changes.
  case chord(keyCode: Int, modifiers: ChordModifiers)
  /// An extra mouse button, by **raw `CGEvent`/`NSEvent` button number**, which
  /// is 0-based: 0 is the left click, 1 the right click, 2 the wheel/middle
  /// click, 3+ the side buttons. Bindable from 2 up. The *display* name is
  /// 1-based, the way mice and their drivers number buttons for users — so the
  /// stored `2` shows as "Mouse 3" and IS the middle (wheel) click. Driven by
  /// `otherMouseDown`/`otherMouseUp` events.
  case mouseButton(Int)

  /// The modifier keys a chord can require, as a stable bit set — the layout is
  /// persisted, so the raw values are a storage contract, not an implementation
  /// detail. Deliberately side-agnostic (left and right ⌃ are the same
  /// requirement): a chord is a shortcut, and no shortcut in macOS distinguishes
  /// the sides. `TriggerKey` keeps the per-side device bits for the lone-modifier
  /// family, where telling the sides apart is the whole point.
  public struct ChordModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
      self.rawValue = rawValue
    }

    public static let control = ChordModifiers(rawValue: 1 << 0)
    public static let option = ChordModifiers(rawValue: 1 << 1)
    public static let shift = ChordModifiers(rawValue: 1 << 2)
    public static let command = ChordModifiers(rawValue: 1 << 3)

    /// Every bit the persisted encoding can carry — the mask the decoder
    /// validates against, so a stray high bit reads as garbage rather than as a
    /// modifier that doesn't exist.
    static let all: ChordModifiers = [.control, .option, .shift, .command]

    /// The glyphs in Apple's canonical order (⌃⌥⇧⌘), so a bound chord reads
    /// the way the same shortcut reads in any macOS menu.
    public var glyphs: String {
      var text = ""
      if contains(.control) { text += "⌃" }
      if contains(.option) { text += "⌥" }
      if contains(.shift) { text += "⇧" }
      if contains(.command) { text += "⌘" }
      return text
    }
  }

  /// Where the mouse-button namespace starts in the persisted slot. Virtual
  /// keycodes are 16-bit, so `0x10000 + button` can never collide with one.
  static let mouseButtonCodeBase = 0x10000

  /// Where the chord namespace starts — one tag above the mouse namespace, whose
  /// values stop at `mouseButtonCodeBase + maximumMouseButton`.
  static let chordCodeBase = 0x20000
  /// How far the modifier bits sit above the keycode in a packed chord: the
  /// keycode occupies the low byte (virtual keycodes are 0–127), the four
  /// modifier bits the byte above it.
  static let chordModifierShift = 8
  /// The keycode half of a packed chord.
  static let chordKeyCodeMask = 0xFF

  /// `fn`'s virtual keycode, kept only as a **migration** input: `fn` was once a
  /// third `TriggerKey` option and was removed, so an install that persisted it
  /// decodes to right ⌥ rather than to the generic right-⌘ garbage fallback —
  /// it's the other right-side modifier, so the user keeps a one-key trigger on
  /// the same side of the keyboard instead of being moved onto ⌘.
  static let legacyFunctionKeyCode = 63

  /// The wheel/middle click's raw button number — the one bindable button apps
  /// commonly act on themselves (open-link-in-new-tab, paste-on-middle-click).
  /// Bindable, but `passThroughNote` cautions about it.
  static let middleMouseButton = 2

  /// The lowest bindable button number: 2 ("Mouse 3"). Buttons 0 and 1 are the
  /// left and right click — binding either would fire dictation on ordinary
  /// mousing, so the recorder refuses them.
  static let minimumMouseButton = 2

  /// The highest bindable button number. `CGEvent` reports up to 32 buttons
  /// (numbers 0–31), so anything past that in the persisted slot is garbage.
  static let maximumMouseButton = 31

  /// The virtual keycodes of the modifier keys themselves. A chord's key half
  /// must be a *non-modifier* key: "⌃⌥ plus ⌘" is not a chord, and a lone
  /// modifier is already its own binding family.
  static let modifierKeyCodes: Set<Int> = [
    54, 55,  // right ⌘, left ⌘
    56, 60,  // left ⇧, right ⇧
    58, 61,  // left ⌥, right ⌥
    59, 62,  // left ⌃, right ⌃
    57,  // Caps Lock
    63,  // fn
  ]

  /// System chords the recorder refuses outright: each is a shortcut macOS or
  /// the frontmost app acts on *while dictation is running*, and the tap is
  /// listen-only, so binding one would both trigger dictation and quit the app /
  /// switch away / open Spotlight underneath it. Small and explicit rather than
  /// a heuristic — a rule nobody can predict is worse than a short list.
  static let reservedChords: Set<Int> = [
    packedChord(keyCode: 12, modifiers: .command),  // ⌘Q — quits the app
    packedChord(keyCode: 13, modifiers: .command),  // ⌘W — closes the window
    packedChord(keyCode: 4, modifiers: .command),  // ⌘H — hides the app
    packedChord(keyCode: 48, modifiers: .command),  // ⌘⇥ — switches apps
    packedChord(keyCode: 49, modifiers: .command),  // ⌘Space — Spotlight
    packedChord(keyCode: 12, modifiers: [.control, .command]),  // ⌃⌘Q — locks the screen
  ]

  /// Decodes the persisted slot into a binding, falling back to the right-⌘
  /// modifier for anything unrecognized — an unset slot (0), a keycode from a
  /// removed option, a mouse code outside the bindable range, or a chord whose
  /// packed halves are structurally invalid. The single decode-with-default rule
  /// shared by `TriggerKeyStore` and the `@AppStorage` views that read the raw
  /// slot directly (so they re-render live on a Settings change).
  public static func fromPersisted(_ code: Int) -> TriggerBinding {
    if let key = TriggerKey(rawValue: code) { return .modifier(key) }
    // The one migration this decoder carries: `fn` was a removed option, and its
    // keycode must land on a deliberate replacement rather than the default.
    if code == legacyFunctionKeyCode { return .modifier(.rightOption) }
    if let binding = mouseButtonBinding(forButton: code - mouseButtonCodeBase) { return binding }
    if let binding = chordBinding(packed: code) { return binding }
    return .modifier(.rightCommand)
  }

  /// The binding for a captured mouse button number, or nil when that button
  /// isn't bindable (0/1 are the left/right click; past 31 `CGEvent` can't
  /// report it).
  public static func mouseButtonBinding(forButton button: Int) -> TriggerBinding? {
    (minimumMouseButton...maximumMouseButton).contains(button) ? .mouseButton(button) : nil
  }

  /// Why a captured chord can't be bound, or nil when it can. The capture UI's
  /// single policy check — which chords are allowed is engine logic with tests
  /// rather than a view's private list, and the reasons are the copy the sheet
  /// shows.
  /// Conforms to `Error` because it is the failure half of the `Result` the
  /// capture policy returns — a refusal is a *decision with a reason*, and the
  /// reason is what the sheet turns into a sentence, so it must survive the call
  /// rather than collapsing into `nil`.
  public enum ChordRefusal: Error, Sendable, Hashable {
    /// No modifier was held. A bare key would type into the focused app on
    /// every dictation, because the tap swallows nothing.
    case bareKey
    /// The "key" was itself a modifier (or Caps Lock / `fn`). A lone modifier is
    /// its own binding family; a chord needs a real key.
    case modifierOnly
    /// A system-reserved chord (`reservedChords`) — it would fire its system
    /// action underneath the dictation.
    case reserved
  }

  /// The binding for a captured chord, or the reason it's refused. `modifiers`
  /// is the exact set that must be held with `keyCode` for the trigger to fire.
  public static func chordBinding(
    forKeyCode keyCode: Int, modifiers: ChordModifiers
  ) -> Result<TriggerBinding, ChordRefusal> {
    if modifierKeyCodes.contains(keyCode) { return .failure(.modifierOnly) }
    if modifiers.isEmpty { return .failure(.bareKey) }
    if reservedChords.contains(packedChord(keyCode: keyCode, modifiers: modifiers)) {
      return .failure(.reserved)
    }
    return .success(.chord(keyCode: keyCode, modifiers: modifiers))
  }

  /// The packed slot value for a chord — the encoding in one place, so the
  /// reserved-chord table above and `persistedValue` below can't drift apart.
  static func packedChord(keyCode: Int, modifiers: ChordModifiers) -> Int {
    chordCodeBase | (modifiers.rawValue << chordModifierShift) | keyCode
  }

  /// The chord a packed slot value names, or nil when it isn't a structurally
  /// valid chord: outside the chord namespace, no modifiers (a bare key was
  /// never bindable, so a stored one is garbage), a modifier as the key half, or
  /// bits set above the four modifiers.
  static func chordBinding(packed code: Int) -> TriggerBinding? {
    guard code >= chordCodeBase else { return nil }
    let payload = code - chordCodeBase
    let keyCode = payload & chordKeyCodeMask
    let modifierBits = payload >> chordModifierShift
    guard modifierBits == modifierBits & ChordModifiers.all.rawValue else { return nil }
    let modifiers = ChordModifiers(rawValue: modifierBits)
    guard !modifiers.isEmpty, !modifierKeyCodes.contains(keyCode) else { return nil }
    return .chord(keyCode: keyCode, modifiers: modifiers)
  }

  /// The value stored in the persisted slot; `fromPersisted` round-trips it.
  /// Internal: `TriggerKeyStore` owns the write, and hosts go through it.
  var persistedValue: Int {
    switch self {
    case .modifier(let key): return key.rawValue
    case .chord(let keyCode, let modifiers):
      return Self.packedChord(keyCode: keyCode, modifiers: modifiers)
    case .mouseButton(let button): return Self.mouseButtonCodeBase + button
    }
  }

  /// Inline sentence form, e.g. "Tap or hold ⌃⌥D to dictate". Chords render as
  /// their macOS glyph sequence; mouse buttons use the 1-based numbering macOS
  /// and pointing-device vendors present to users (button number 3 is
  /// "Mouse 4").
  public var label: String {
    switch self {
    case .modifier(let key): return key.label
    case .chord(let keyCode, let modifiers):
      return modifiers.glyphs + Self.keyLabel(forKeyCode: keyCode)
    case .mouseButton(let button): return "Mouse \(button + 1)"
    }
  }

  /// The caution this binding deserves in the UI, or nil when it needs none.
  ///
  /// The tap is `.listenOnly` and **swallows nothing**, so a binding the system
  /// or the focused app also acts on will do both things at once. That is
  /// harmless for a lone right-side modifier (which types nothing) and for a
  /// side button (which almost nothing claims), and worth saying plainly for the
  /// two bindings where it bites: the wheel click, which browsers and terminals
  /// use, and any chord, which the frontmost app may already own. Engine-side
  /// rather than in the view so the wording is testable and the Settings footer
  /// and the capture sheet can't disagree.
  public var passThroughNote: String? {
    switch self {
    case .modifier:
      return nil
    case .chord:
      return "Blurt doesn't intercept \(label) — an app that already uses it will still act on it."
    case .mouseButton(let button):
      guard button == Self.middleMouseButton else { return nil }
      return
        "Mouse 3 is the wheel click. Blurt doesn't intercept it, so apps that use it "
        + "(opening a link in a new tab, for example) will still act on it."
    }
  }

  /// The display name of a chord's key half, in the form a macOS menu would use
  /// (a glyph for the editing keys, the bare character for letters and digits).
  /// Unknown codes render as `key <n>` rather than nothing, so a binding is
  /// always nameable in the picker.
  static func keyLabel(forKeyCode keyCode: Int) -> String {
    if let name = keyLabels[keyCode] { return name }
    return "key \(keyCode)"
  }

  /// Virtual keycode → display name, for every key a chord can name. The values
  /// are the US-layout characters and the standard glyphs; a non-US layout may
  /// print a different character on the same physical key, which is the same
  /// approximation every keyboard-shortcut UI on the platform makes.
  private static let keyLabels: [Int: String] = {
    var labels: [Int: String] = [
      // Letters, in keycode order.
      0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
      38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q",
      15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
      // Digits.
      29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
      28: "8", 25: "9",
      // Punctuation.
      27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",",
      47: ".", 44: "/", 50: "`",
      // Editing and navigation, as the glyphs a menu shows.
      36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 71: "⌧", 76: "⌤",
      114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
      123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    // F1–F20, whose keycodes are scattered rather than contiguous.
    let functionKeys = [
      122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9,
      109: 10, 103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17,
      79: 18, 80: 19, 90: 20,
    ]
    for (code, number) in functionKeys { labels[code] = "F\(number)" }
    return labels
  }()
}
