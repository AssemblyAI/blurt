public import Foundation

/// One thing the Control Your Mac key does, as `VoiceCommandPlanner` reads it
/// out of the model's reply. A closed set Blurt carries out itself
/// (`VoiceCommandPerforming`), never script the model wrote. That bounds what
/// a plan can do by itself — but a `type` step into a terminal followed by
/// return runs what it typed, so the set is only as closed as the app in
/// front: typing into terminals is allowed, owner-directed (2026-11-03).
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

  /// The actions a plan names, by the names the planner's instruction and its
  /// JSON schema use — one list, so the schema (`VoiceCommandPlanner`) and the
  /// parse (`VoiceCommandStep+Parse`) can't drift apart.
  enum Action: String, CaseIterable, Sendable {
    case openApp = "open_app"
    case quitApp = "quit_app"
    case hideApp = "hide_app"
    case openURL = "open_url"
    case shortcut, type, media
    case pressButton = "press_button"
    case menu, press, focus, select
    case showMenu = "show_menu"
    case setValue = "set_value"
    case increment, decrement, scroll, window
  }

  /// The URL schemes `openURL` takes. Any other would hand the model a door
  /// into whichever app claims the scheme (`file:`, `x-apple.systempreferences:`,
  /// an app's own deep links), so the step is refused instead.
  static let allowedSchemes: Set<String> = ["http", "https", "mailto"]
  /// The most text one `type` step pastes.
  static let maxTypedCharacters = 2_000
  /// The deepest a menu path goes: a menu, a submenu, its item.
  static let maxMenuDepth = 4
  /// The most words a spoken command may have. Commands are short; a key
  /// held near a TV took a 90-second election broadcast as one (2026-11-04),
  /// and anything said near the Mac is otherwise instructions Blurt acts on.
  static let maxCommandWords = 40

  /// The step's action: its kind alone, which is what the public log shows —
  /// never the app, path, link or text it names.
  var action: Action {
    switch self {
    case .openApp:
      .openApp

    case .quitApp:
      .quitApp

    case .hideApp:
      .hideApp

    case .openURL:
      .openURL

    case .shortcut:
      .shortcut

    case .type:
      .type

    case .media:
      .media

    case .pressButton:
      .pressButton

    case .chooseMenuItem:
      .menu

    case .pressElement:
      .press

    case .focusElement:
      .focus

    case .select:
      .select

    case .showMenu:
      .showMenu

    case .setValue:
      .setValue

    case .increment:
      .increment

    case .decrement:
      .decrement

    case .scroll:
      .scroll

    case .window:
      .window
    }
  }

  /// The snapshot element the step acts on, if it names one.
  var elementID: Int? {
    switch self {
    case .pressElement(let id), .focusElement(let id), .increment(let id), .decrement(let id), .showMenu(let id),
      .select(let id), .setValue(let id, _):
      id

    case .scroll(_, let id):
      id

    default:
      nil
    }
  }
}
