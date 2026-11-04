import CoreGraphics
import Foundation

/// What the planner is shown of the screen when a command is spoken: the
/// app in front, its focused window's title, and the elements in that window
/// the user could act on, numbered — read from the Accessibility tree, never a
/// screenshot. The numbers are this snapshot's own: a `press` or `focus` step
/// names one, and the performer acts on the element it was read from.
public struct ScreenContext: Equatable, Sendable {
  public struct Element: Equatable, Sendable {
    /// The number the planner names it by.
    public let id: Int
    /// What kind of control it is, in words: "button", "link", "text field".
    public let kind: String
    public let label: String

    public init(id: Int, kind: String, label: String) {
      self.id = id
      self.kind = kind
      self.label = label
    }
  }

  public let appName: String?
  public let windowTitle: String?
  public let elements: [Element]
  /// The read stopped before the window's end (the list's cap, or its time):
  /// an element not listed may still be on screen.
  public let incomplete: Bool

  public init(appName: String?, windowTitle: String? = nil, elements: [Element] = [], incomplete: Bool = false) {
    self.appName = appName
    self.windowTitle = windowTitle
    self.elements = elements
    self.incomplete = incomplete
  }

  /// The most elements one snapshot lists: enough for a mail window's
  /// toolbar, sidebar and message actions, and a bounded prompt.
  static let maxElements = 150
  /// The most of a label the planner is shown.
  static let maxLabelCharacters = 80

  /// The snapshot as the planner's user turn shows it, before the command.
  /// Nil with no app in front. `fence`: the request's random code, on the
  /// window block's opening and closing tags (Peekaboo's datamarking), so the
  /// block's edges are ones no screen text could have written.
  func promptText(fence: String) -> String? {
    guard let appName else { return nil }
    var text = "<frontmost_app>\n\(Self.quoted(appName))\n</frontmost_app>"
    guard windowTitle != nil || !elements.isEmpty else { return text }
    let title = windowTitle.map { " title=\"\(Self.quoted($0))\"" } ?? ""
    var lines = elements.map { "[\($0.id)] \($0.kind) \"\(Self.quoted($0.label))\"" }
    if incomplete { lines.append("(More is on screen than is listed: an element not listed may still be there.)") }
    text += "\n\n<window fence=\"\(fence)\"\(title)>\n" + lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    return text + "</window fence=\"\(fence)\">"
  }

  /// A fresh fence code for one request.
  static func newFence() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

  /// A label on one line, inside its quotes, unable to write markup: every
  /// line break, control and format character (a carriage return, U+2028, a
  /// zero-width space, a bidi override) becomes a space, a quote becomes an
  /// apostrophe, and angle brackets become guillemets, so page text can
  /// neither end its line or its label early nor write a tag.
  static func quoted(_ label: String) -> String {
    let flattened = CharacterSet.newlines.union(.controlCharacters).union(.illegalCharacters)
    let scalars = label.unicodeScalars.map { scalar -> String in
      if flattened.contains(scalar) || scalar.properties.generalCategory == .format { return " " }
      switch scalar {
      case "\"": return "'"
      case "<": return "‹"
      case ">": return "›"
      default: return String(scalar)
      }
    }
    return String(scalars.joined().prefix(maxLabelCharacters))
  }
}

/// Reading a window's Accessibility tree into `ScreenContext.Element`s, over
/// any node type so the walk is tested without one.
enum ScreenSnapshot {
  /// One element a walk keeps: the node, to act on later, and how it's listed.
  struct Entry<Node> {
    let node: Node
    let kind: String
    let label: String
  }

  /// The actionable nodes under `root`, breadth first — a window's toolbar
  /// before the depths of its content — visiting at most `visitLimit` and
  /// keeping at most `keepLimit`. `describe` answers how a node is listed, or
  /// nil to leave it out (not actionable, no label, off screen, a password
  /// field). `skip` leaves a node's whole subtree out (the web area, walked on
  /// its own); `shouldStop` ends the walk early (the read's deadline).
  static func entries<Node>(
    from root: Node, children: (Node) -> [Node], describe: (Node) -> (kind: String, label: String)?,
    visitLimit: Int = ElementSearch.maxElements, keepLimit: Int = ScreenContext.maxElements,
    skip: (Node) -> Bool = { _ in false }, shouldStop: () -> Bool = { false },
    onIncomplete: () -> Void = {}
  ) -> [Entry<Node>] {
    var queue = [root]
    var index = 0
    var entries: [Entry<Node>] = []
    while index < queue.count, index < visitLimit, entries.count < keepLimit, !shouldStop() {
      let node = queue[index]
      index += 1
      if index > 1, skip(node) { continue }
      if let described = describe(node) {
        entries.append(Entry(node: node, kind: described.kind, label: described.label))
      }
      queue += children(node)
    }
    // Stopped with nodes still to visit: a cap or the clock ended it.
    if index < queue.count { onIncomplete() }
    return entries
  }

  /// How the 150 listed elements are shared when the window holds a web
  /// page (Chrome, Safari, an Electron app): most go to the page, walked on
  /// its own, or a browser's tab strip and bookmarks bar fill the list first.
  static let webShare = 100
  /// Fewer listed elements than this in a web area means the browser is still
  /// building its tree (Chrome builds it asynchronously once a client reads a
  /// role): the read waits and looks again (`webRetryDelays`).
  static let sparseWebArea = 5
  static let webRetryDelays: [Duration] = [.milliseconds(300), .milliseconds(600)]
  /// The most one read spends walking, and on each Accessibility call: a
  /// busy page answers slowly, and the command waits on this.
  static let readBudget: Duration = .milliseconds(500)
  static let callTimeout: Float = 0.25
  /// The most the search for a web area spends before the walks start.
  static let webAreaSearchBudget: Duration = .milliseconds(250)

  /// Whether an element at `frame` is on screen in `bounds` (the window, or
  /// the page inside it): a page exposes everything, scrolled out of view
  /// too. No frame to go on, or no bounds, keeps it.
  static func isVisible(_ frame: CGRect?, in bounds: CGRect?) -> Bool {
    guard let frame, let bounds else { return true }
    return frame.width > 0 && frame.height > 0 && frame.intersects(bounds)
  }

  /// Where a fallback click on an element at `frame` lands: its centre, and
  /// only when that's inside `bounds`, the element's window. Nil otherwise —
  /// a click outside the window would land on whatever is beside it.
  static func clickPoint(_ frame: CGRect, within bounds: CGRect) -> CGPoint? {
    guard frame.width > 0, frame.height > 0 else { return nil }
    let centre = CGPoint(x: frame.midX, y: frame.midY)
    return bounds.contains(centre) ? centre : nil
  }

  /// Whether an app is built on Electron, from its Info.plist: such an app
  /// builds its Accessibility tree only once `AXManualAccessibility` is set
  /// (the switch Electron documents; Peekaboo detects it the same way).
  static func isElectron(infoDictionary: [String: Any]) -> Bool {
    infoDictionary["ElectronAsarIntegrity"] != nil
  }

  /// Chromium browsers, by bundle id: they build a page's Accessibility tree
  /// only while `AXEnhancedUserInterface` is set on them, and tear it down
  /// when it's cleared — measured on Chrome (2026-11-03): no web area at all
  /// without it, a full one about 2.1 s after it goes on. They don't
  /// implement Electron's `AXManualAccessibility` (`-25205`).
  static let chromiumBrowsers: Set<String> = [
    "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
    "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
    "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
  ]

  /// The waits for a Chromium page tree that isn't there yet: about two
  /// seconds in all, the build's measured length, most of it already spent
  /// while the command was spoken.
  static let webAreaWaits: [Duration] = [.milliseconds(400), .milliseconds(600), .milliseconds(1_000)]

  /// Whether the app at `bundleURL` is a Chromium browser.
  static func isChromium(bundleURL: URL?) -> Bool {
    guard let bundleURL, let id = Bundle(url: bundleURL)?.bundleIdentifier else { return false }
    return chromiumBrowsers.contains(id)
  }

  /// How long after a command press the enhanced-interface flag is cleared
  /// if nothing clears it first (a press abandoned before a command ran).
  static let enhancedInterfaceLinger: Duration = .seconds(30)

  /// Roles listed only when they take `AXPress`: a web page's clickable
  /// `<div>` is an `AXGroup` with a press action, not a button.
  static let clickableRoles: Set<String> = ["AXGroup", "AXStaticText", "AXImage", "AXCell"]

  /// The listed kind of an Accessibility role and subrole, or nil for a role
  /// the planner can't act on. A secure text field is never listed: its
  /// label is harmless, but nothing should dictate into it.
  static func kind(role: String, subrole: String?) -> String? {
    if subrole == "AXSecureTextField" { return nil }
    if subrole == "AXSearchField" { return "search field" }
    return roleKinds[role]
  }

  private static let roleKinds: [String: String] = [
    "AXButton": "button", "AXMenuButton": "menu button", "AXPopUpButton": "pop-up menu",
    "AXCheckBox": "checkbox", "AXRadioButton": "tab or option", "AXLink": "link",
    "AXTextField": "text field", "AXTextArea": "text area", "AXComboBox": "combo box",
    "AXDisclosureTriangle": "disclosure triangle", "AXIncrementor": "stepper", "AXSlider": "slider",
    // A sidebar or list entry (Music's Songs, a Finder file, a Mail message):
    // named by the text inside it (`AXRead.names`).
    "AXRow": "row", "AXMenuItem": "menu item",
  ]

  /// Whether the kind is somewhere to type, for a `focus` step.
  static func isTextEntry(_ kind: String) -> Bool {
    ["text field", "text area", "search field", "combo box"].contains(kind)
  }
}

/// What a press is judged by: the app's focused element, its focused
/// window's title, the pressed element's value, and whether it's still on
/// screen. The same before and after means the press changed nothing Blurt
/// can see, and a click is tried instead.
struct PressFingerprint {
  /// The focused element's identity (`CFHash`), not its contents.
  let focusedElement: Int?
  let windowTitle: String?
  let value: String?
  let onScreen: Bool

  /// Whether anything a working press would change is different from `earlier`.
  func changed(since earlier: PressFingerprint) -> Bool {
    focusedElement != earlier.focusedElement || windowTitle != earlier.windowTitle || value != earlier.value
      || onScreen != earlier.onScreen
  }
}
