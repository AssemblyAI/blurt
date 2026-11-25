import Foundation

/// A keyboard shortcut: modifiers and one key. Parsed from the model's
/// "cmd+shift+t" form (`init?(_:)`).
public struct KeyChord: Equatable, Sendable {
  public struct Modifiers: OptionSet, Sendable {
    public static let command = Self(rawValue: 1 << 0)
    public static let shift = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let control = Self(rawValue: 1 << 3)

    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }
  }

  /// Which key the chord presses.
  public enum Key: Equatable, Sendable {
    /// The key that types this character (a letter, digit or punctuation mark,
    /// lowercase), found on the user's own layout when the chord is pressed: ⌘K
    /// is wherever K is, on Dvorak or AZERTY too.
    case character(Character)
    /// A key that types no character (return, an arrow, F5), by virtual key
    /// code (`kVK_*`): it is in the same place on every layout.
    case code(UInt16)
  }

  private static let modifierNames: [String: Modifiers] = [
    "cmd": .command, "command": .command, "⌘": .command,
    "shift": .shift, "⇧": .shift,
    "opt": .option, "option": .option, "alt": .option, "⌥": .option,
    "ctrl": .control, "control": .control, "⌃": .control,
  ]

  /// The ANSI layout's virtual key codes (`Events.h`) for the characters the
  /// planner's instruction offers: the fallback when the user's layout gives
  /// no key for one (`KeyboardLayout`).
  static let ansiCharacterCodes: [Character: UInt16] = {
    let letters: [(Character, UInt16)] = [
      ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04), ("g", 0x05), ("z", 0x06),
      ("x", 0x07), ("c", 0x08), ("v", 0x09), ("b", 0x0B), ("q", 0x0C), ("w", 0x0D), ("e", 0x0E),
      ("r", 0x0F), ("y", 0x10), ("t", 0x11), ("o", 0x1F), ("u", 0x20), ("i", 0x22), ("p", 0x23),
      ("l", 0x25), ("j", 0x26), ("k", 0x28), ("n", 0x2D), ("m", 0x2E),
    ]
    let digits: [(Character, UInt16)] = [
      ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15), ("6", 0x16), ("5", 0x17), ("9", 0x19),
      ("7", 0x1A), ("8", 0x1C), ("0", 0x1D),
    ]
    let punctuation: [(Character, UInt16)] = [
      ("=", 0x18), ("-", 0x1B), ("]", 0x1E), ("[", 0x21), ("'", 0x27), (";", 0x29), ("\\", 0x2A),
      (",", 0x2B), ("/", 0x2C), (".", 0x2F), ("`", 0x32),
    ]
    return Dictionary(uniqueKeysWithValues: letters + digits + punctuation)
  }()

  /// The keys that type no character, by the names the instruction offers.
  static let namedKeyCodes: [String: UInt16] = [
    "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33,
    "escape": 0x35, "esc": 0x35, "forward_delete": 0x75, "home": 0x73, "end": 0x77, "page_up": 0x74,
    "page_down": 0x79, "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
    "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
  ]

  /// The other names a plan may use for a key above, accepted but never
  /// written back: the log and the eval corpus spell a key as the
  /// instruction does ("return", not "enter").
  static let keyAliases: Set<String> = ["enter", "backspace", "esc"]

  public let modifiers: Modifiers
  public let key: Key

  /// The key's code on the ANSI (US) layout: where a character key is when
  /// the user's own layout can't be read or doesn't have it.
  var ansiKeyCode: UInt16 {
    switch key {
    case .code(let code):
      code

    // Every character `key(named:)` accepts is in the table.
    case .character(let character):
      Self.ansiCharacterCodes[character] ?? 0
    }
  }

  /// "cmd+shift+t", "ctrl+tab", "escape": any modifiers, then exactly one key,
  /// joined by `+`. Nil for an unknown name, no key, or two of them.
  public init?(_ spec: String) {
    var heldModifiers: Modifiers = []
    var namedKey: Key?
    for token in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
      if let modifier = Self.modifierNames[token] {
        heldModifiers.insert(modifier)
      } else if namedKey == nil, let parsed = Self.key(named: token) {
        namedKey = parsed
      } else {
        return nil
      }
    }
    guard let namedKey else {
      return nil
    }
    self.init(modifiers: heldModifiers, key: namedKey)
  }

  public init(modifiers: Modifiers, key: Key) {
    self.modifiers = modifiers
    self.key = key
  }

  private static func key(named token: String) -> Key? {
    if let code = namedKeyCodes[token] {
      return .code(code)
    }
    guard let character = token.onlyElement, ansiCharacterCodes[character] != nil else {
      return nil
    }
    return .character(character)
  }
}
