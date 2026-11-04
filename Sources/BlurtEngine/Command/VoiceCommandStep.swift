import Foundation

/// One thing the Control Your Mac key does, as `VoiceCommandPlanner` reads it
/// out of the model's reply. A closed set Blurt carries out itself
/// (`VoiceCommandPerforming`), never script the model wrote: the most a
/// mis-heard command can do is one of these.
public enum VoiceCommandStep: Equatable, Sendable {
  /// Open an app, or bring it forward if it is already running.
  case openApp(String)
  case quitApp(String)
  case hideApp(String)
  /// A web page, a web search or a new email: `http`, `https` and `mailto`
  /// only (`VoiceCommandStep.allowedSchemes`).
  case openURL(URL)
  /// A keyboard shortcut, pressed in the frontmost app.
  case shortcut(KeyChord)
  /// Text pasted into the focused field, as a dictation is
  /// (`DictationSession.typeText`).
  case type(String)
  case media(MediaKey)
  /// Press the button (or other pressable element) with this name in the
  /// frontmost app's focused window, through Accessibility (`AXPress`).
  case pressButton(String)
  /// Choose a menu-bar item by its path from the menu's title, such as
  /// ["File", "New Window"], through Accessibility. Unlike a shortcut it
  /// doesn't depend on the keyboard layout.
  case chooseMenuItem([String])
  /// Press the element the command's `ScreenContext` numbered so.
  case pressElement(Int)
  /// Put the cursor in the text field the `ScreenContext` numbered so, for a
  /// `type` step after it.
  case focusElement(Int)
  /// Scroll a page at a time: the scroll area holding the listed element,
  /// or with none named, the window's main one.
  case scroll(ScrollDirection, element: Int?)
  /// Set a listed slider or stepper to `value`. Never a text field: text
  /// goes in by `focus` and a pasted `type`, as every insertion does.
  case setValue(element: Int, value: String)
  /// Step a listed slider or stepper by one notch.
  case increment(Int)
  case decrement(Int)
  /// Open a listed element's context menu, as a right-click would.
  case showMenu(Int)
  /// Select a listed row: a file in the Finder, a message in Mail.
  case select(Int)
  case window(WindowOperation)

  /// The step's action name, for the log: what ran, never what was typed.
  var logName: String {
    switch self {
    case .openApp(let app): "open_app \(app)"
    case .quitApp(let app): "quit_app \(app)"
    case .hideApp(let app): "hide_app \(app)"
    case .openURL(let url): "open_url \(url.host() ?? url.scheme ?? "")"
    case .shortcut: "shortcut"
    case .type(let text): "type (\(text.count) characters)"
    case .media(let key): "media \(key.rawValue)"
    case .pressButton: "press_button"
    case .chooseMenuItem(let path): "menu \(path.joined(separator: " › "))"
    case .window(let operation): "window \(operation.rawValue)"
    case .scroll(let direction, let id): "scroll \(direction.rawValue)\(id.map { " #\($0)" } ?? "")"
    default: "element step #\(elementID ?? 0)"
    }
  }

  /// The snapshot element the step acts on, if it names one.
  var elementID: Int? {
    switch self {
    case .pressElement(let id), .focusElement(let id), .increment(let id), .decrement(let id), .showMenu(let id),
      .select(let id), .setValue(let id, _):
      id
    case .scroll(_, let id): id
    default: nil
    }
  }

  /// The URL schemes `openURL` takes. Any other would hand the model a door
  /// into whichever app claims the scheme (`file:`, `x-apple.systempreferences:`,
  /// an app's own deep links), so the step is refused instead.
  static let allowedSchemes: Set<String> = ["http", "https", "mailto"]
  /// The most text one `type` step pastes.
  static let maxTypedCharacters = 2_000
  /// The deepest a menu path goes: a menu, a submenu, its item.
  static let maxMenuDepth = 4
}

/// The media keys a command can press: what the keyboard's top row does.
public enum MediaKey: String, CaseIterable, Sendable {
  case volumeUp = "volume_up"
  case volumeDown = "volume_down"
  case mute
  case playPause = "play_pause"
  case nextTrack = "next_track"
  case previousTrack = "previous_track"

  /// The `NX_KEYTYPE_*` code the system-defined event carries.
  var systemKeyType: Int {
    switch self {
    case .volumeUp: 0
    case .volumeDown: 1
    case .mute: 7
    case .playPause: 16
    case .nextTrack: 17
    case .previousTrack: 18
    }
  }
}

/// A keyboard shortcut: modifiers and one key. Parsed from the model's
/// "cmd+shift+t" form (`init?(_:)`).
public struct KeyChord: Equatable, Sendable {
  public struct Modifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = Modifiers(rawValue: 1 << 0)
    public static let shift = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let control = Modifiers(rawValue: 1 << 3)
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

  public let modifiers: Modifiers
  public let key: Key

  /// "cmd+shift+t", "ctrl+tab", "escape": any modifiers, then exactly one key,
  /// joined by `+`. Nil for an unknown name, no key, or two of them.
  public init?(_ spec: String) {
    var modifiers: Modifiers = []
    var key: Key?
    for token in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
      if let modifier = Self.modifierNames[token] {
        modifiers.insert(modifier)
      } else if key == nil, let parsed = Self.key(named: token) {
        key = parsed
      } else {
        return nil
      }
    }
    guard let key else { return nil }
    self.init(modifiers: modifiers, key: key)
  }

  public init(modifiers: Modifiers, key: Key) {
    self.modifiers = modifiers
    self.key = key
  }

  /// The key's code on the ANSI (US) layout: where a character key is when
  /// the user's own layout can't be read or doesn't have it.
  var ansiKeyCode: UInt16 {
    switch key {
    case .code(let code): code
    // Every character `key(named:)` accepts is in the table.
    case .character(let character): Self.ansiCharacterCodes[character] ?? 0
    }
  }

  private static func key(named token: String) -> Key? {
    if let code = namedKeyCodes[token] { return .code(code) }
    guard token.count == 1, let character = token.first, ansiCharacterCodes[character] != nil else { return nil }
    return .character(character)
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
}

/// Carries out the steps a command planned, other than `type` (which pastes
/// through the session's injector). Public so a host can stand in its own
/// (the engine's tests do).
public protocol VoiceCommandPerforming: Sendable {
  /// What's on screen when the command was spoken, for the planner: the app
  /// in front ("new tab" means that app's) and what its window offers to act
  /// on. The elements' numbers stay this performer's until the next snapshot.
  func screenContext() async -> ScreenContext
  func perform(_ step: VoiceCommandStep) async throws
  /// A command press proved itself and the command is about to be spoken:
  /// time the performer can spend getting the screen ready to read (a
  /// Chromium browser takes about two seconds to build its page tree).
  func commandStarting() async
  /// The command ran, failed, or was abandoned: undo what
  /// `commandStarting` changed.
  func commandEnded() async
}

extension VoiceCommandPerforming {
  public func commandStarting() async {}
  public func commandEnded() async {}
}

enum VoiceCommandError: Error, Equatable, LocalizedError {
  /// The model planned nothing: the command isn't one these steps can do.
  case notUnderstood
  /// The reply wasn't the JSON the instruction asks for.
  case malformedReply
  /// The reply stopped at the token cap, part-way through the plan.
  case truncatedReply
  case unsupportedAction(String)
  /// An `open_url` whose scheme isn't in `VoiceCommandStep.allowedSchemes`.
  case unsafeURL(String)
  case unknownShortcut(String)
  case tooManySteps
  case appNotFound(String)
  case appNotRunning(String)
  /// No pressable element by that name in the frontmost window.
  case buttonNotFound(String)
  /// No menu-bar item at that path in the frontmost app.
  case menuItemNotFound([String])
  /// A `press` or `focus` step named a number the snapshot didn't list.
  case unknownElement(Int)
  /// The app in front changed between the snapshot and an element step.
  case screenChanged
  /// The listed element went away, or doesn't take the step (focus on a button).
  case elementGone
  /// A step the code refuses whatever the plan says (`DestructiveGuard`).
  case refused(String)
  /// The system refused the step (a URL nothing opened, an event not built).
  case couldNotPerform(String)

  var errorDescription: String? {
    switch self {
    case .notUnderstood: "Blurt can’t do that command."
    case .malformedReply: "The LLM Gateway’s plan for that command couldn’t be read."
    case .truncatedReply: "The LLM Gateway’s plan for that command was cut short."
    case .unsupportedAction(let action): "The command needed an action Blurt doesn’t have (\(action))."
    case .unsafeURL(let url): "Blurt doesn’t open links like \(url)."
    case .unknownShortcut(let keys): "Blurt doesn’t know the shortcut \(keys)."
    case .tooManySteps: "That command has too many steps."
    case .appNotFound(let name): "No app named \(name) is installed."
    case .appNotRunning(let name): "\(name) isn’t open."
    case .buttonNotFound(let name): "There’s no \(name) button in the window in front."
    case .menuItemNotFound(let path): "There’s no \(path.joined(separator: " › ")) menu item."
    case .couldNotPerform(let what): "Blurt couldn’t \(what)."
    case .refused(let what): "Blurt won’t \(what)."
    case .unknownElement(let id): "The plan named element \(id), which isn’t on screen."
    case .screenChanged: "The window changed before Blurt got to it."
    case .elementGone: "That control isn’t there any more."
    }
  }

  /// Whether the planner asks again once, showing the model this error: the
  /// plan was unusable rather than deliberate. Not an empty plan (the model's
  /// own "can't"), a refusal (the code's own "won't"), or a cut-off reply.
  var isRetryable: Bool {
    switch self {
    case .malformedReply, .unsupportedAction, .unsafeURL, .unknownShortcut, .tooManySteps, .unknownElement: true
    default: false
    }
  }

  /// The words on the pill for the failures a user can act on: the app name
  /// is the diagnosis, so it goes on the pill rather than behind a hover.
  var pillNotice: PillNotice? {
    switch self {
    case .notUnderstood: PillNotice(subject: "Blurt can’t", predicate: "do that")
    case .refused: PillNotice(subject: "Blurt won’t", predicate: "do that")
    case .appNotFound(let name): PillNotice(subject: name, predicate: "isn’t installed")
    case .appNotRunning(let name): PillNotice(subject: name, predicate: "isn’t open")
    case .buttonNotFound(let name): PillNotice(subject: name, predicate: "isn’t on screen")
    case .menuItemNotFound(let path): PillNotice(subject: path.last ?? "That item", predicate: "isn’t in the menus")
    default: nil
    }
  }
}
