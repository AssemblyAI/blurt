import CoreGraphics

/// Reading a window's Accessibility tree into `ScreenContext.Element`s, over
/// any node type so the walk is tested without one.
enum ScreenSnapshot {
  /// One element a walk keeps: the node, to act on later, and how it's listed.
  struct Entry<Node> {
    let node: Node
    let kind: String
    let label: String
  }

  /// How the 150 listed elements are shared when the window holds a web
  /// page (Chrome, Safari, an Electron app): the page is promised at least
  /// this many, walked on its own, or a browser's tab strip and bookmarks bar
  /// fill the list first — and it takes any of the rest the window doesn't use.
  static let webShare = 100
  /// Fewer listed elements than this in a web area means the browser is still
  /// building its tree (Chrome builds it asynchronously once a client reads a
  /// role): the read waits and looks again (`webRetryDelays`).
  static let sparseWebArea = 5
  static let webRetryDelays: [Duration] = [.milliseconds(300), .milliseconds(600)]
  /// The most one walk spends, and on each Accessibility call: a busy
  /// window answers slowly. The read runs while the command transcribes
  /// (`.readScreen`), so this mostly overlaps that rather than adding to it.
  /// More doesn't buy a slow app more: at a second, Music (whose content area
  /// answers at up to ~130 ms a call) still listed only its toolbar and
  /// sidebar, its content rows sitting under groups that take seconds to
  /// walk — measured 2026-11-03. A fast app finishes long before either.
  static let readBudget: Duration = .milliseconds(500)
  static let callTimeout: Float = 0.25
  /// The most the search for a web area spends before the walks start.
  static let webAreaSearchBudget: Duration = .milliseconds(250)

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

  /// How long after a command press the enhanced-interface flag is cleared
  /// if nothing clears it first (a press abandoned before a command ran).
  static let enhancedInterfaceLinger: Duration = .seconds(30)

  /// Roles listed only when they take `AXPress`: a web page's clickable
  /// `<div>` is an `AXGroup` with a press action, not a button.
  static let clickableRoles: Set<String> = ["AXGroup", "AXStaticText", "AXImage", "AXCell"]

  private static let roleKinds: [String: String] = [
    "AXButton": "button", "AXMenuButton": "menu button", "AXPopUpButton": "pop-up menu",
    "AXCheckBox": "checkbox", "AXRadioButton": "tab or option", "AXLink": "link",
    "AXTextField": "text field", "AXTextArea": "text area", "AXComboBox": "combo box",
    "AXDisclosureTriangle": "disclosure triangle", "AXIncrementor": "stepper", "AXSlider": "slider",
    // A sidebar or list entry (Music's Songs, a Finder file, a Mail message):
    // named by the text inside it (`firstText`).
    "AXRow": "row", "AXMenuItem": "menu item",
  ]

  /// The roles a user types into: where a `focus` step may put the cursor,
  /// whose `AXValue` is never read — it's what was typed — and whose label is
  /// a title, a description or a placeholder. One list for all three rules.
  static let textEntryRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
  /// The single-line ones, whose contents a focus selects (as tabbing in does).
  static let singleLineEntryRoles: Set<String> = ["AXTextField", "AXComboBox"]
  /// The roles whose `AXValue` is their name: a link's text, a static text's
  /// words, a pop-up's choice, a web list's option (1Password's items are
  /// `AXMenuItem`s named only by their value, 2026-11-04). Every other
  /// role's value goes unread.
  static let valueNamedRoles: Set<String> = ["AXLink", "AXStaticText", "AXPopUpButton", "AXMenuButton", "AXMenuItem"]
  /// What a `select` step may select, and a `set_value` / `increment` /
  /// `decrement` step may change: anything else is refused before it could
  /// fall back to a click on, say, a button.
  static let selectableRoles: Set<String> = ["AXRow", "AXCell", "AXRadioButton"]
  static let adjustableRoles: Set<String> = ["AXSlider", "AXIncrementor", "AXValueIndicator"]

  /// The actionable nodes under `root`, breadth first — a window's toolbar
  /// before the depths of its content — visiting at most `visitLimit` and
  /// keeping at most `keepLimit`. `describe` answers how a node is listed, or
  /// nil to leave it out (not actionable, no label, off screen, a password
  /// field). `skip` leaves a node's whole subtree out (the web area, walked on
  /// its own); `shouldStop` ends the walk early (the read's deadline).
  static func entries<Node>(
    from root: Node,
    children: (Node) -> [Node],
    describe: (Node) -> (kind: String, label: String)?,
    visitLimit: Int = ElementSearch.maxElements,
    keepLimit: Int = ScreenContext.maxElements,
    skip: (Node) -> Bool = { _ in false },
    shouldStop: () -> Bool = { false },
    onIncomplete: () -> Void = {
      // Nothing to report: a caller that cares whether the walk finished passes its own.
    }
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

  /// Whether an element at `frame` is on screen in `bounds` (the window, or
  /// the page inside it): a page exposes everything, scrolled out of view
  /// too. No frame to go on, or no bounds, keeps it.
  static func isVisible(_ frame: CGRect?, in bounds: CGRect?) -> Bool {
    guard let frame, let bounds else {
      return true
    }
    return frame.width > 0 && frame.height > 0 && frame.intersects(bounds)
  }

  /// Where a fallback click on an element at `frame` lands: its centre, and
  /// only when that's inside `bounds`, the element's window. Nil otherwise —
  /// a click outside the window would land on whatever is beside it.
  static func clickPoint(_ frame: CGRect, within bounds: CGRect) -> CGPoint? {
    guard frame.width > 0, frame.height > 0 else {
      return nil
    }
    let centre = CGPoint(x: frame.midX, y: frame.midY)
    return bounds.contains(centre) ? centre : nil
  }

  /// The listed kind of an Accessibility role and subrole, or nil for a role
  /// the planner can't act on. A password field is never listed
  /// (`FocusCapture.isSecureField`): its label is harmless, but nothing
  /// should dictate into it.
  static func kind(role: String, subrole: String?) -> String? {
    if FocusCapture.isSecureField(role: role, subrole: subrole) {
      return nil
    }
    if subrole == "AXSearchField" {
      return "search field"
    }
    return roleKinds[role]
  }

  /// The kinds the snapshot lists elements of `roles` under: a text field's
  /// search-field subrole included. A role listed only when it takes a press (`clickableRoles`: a cell, a
  /// web page's `<div>`) is listed as "clickable".
  static func kinds(of roles: Set<String>) -> Set<String> {
    var kinds = Set(roles.compactMap { roleKinds[$0] })
    if roles.contains("AXTextField") { kinds.insert("search field") }
    if !roles.isDisjoint(with: clickableRoles) { kinds.insert("clickable") }
    return kinds
  }

  /// How a node is listed, or nil to leave it out: off screen in `bounds`, a
  /// role the planner can't act on, or a web page's group or text that takes
  /// no press. `pressable` is asked last — it's a round trip of its own, and
  /// most nodes are settled without it.
  static func listedKind(
    role: String, subrole: String?, frame: CGRect?, bounds: CGRect?, pressable: () -> Bool
  ) -> String? {
    guard isVisible(frame, in: bounds) else {
      return nil
    }
    if let kind = kind(role: role, subrole: subrole) {
      return kind
    }
    return clickableRoles.contains(role) && pressable() ? "clickable" : nil
  }

  /// What a listed node is called. Its own label (`own`: title, description,
  /// a value-named role's value) first; a text entry then goes by its
  /// placeholder ("Search") or the `<label>` it borrows — never its contents,
  /// and its kind when it has neither (`describe`); anything else by the
  /// label it borrows, then the text inside it.
  static func label(
    role: String, own: [String], placeholder: String?, borrowed: () -> String?, inner: () -> String?
  ) -> String? {
    if let first = own.first {
      return first
    }
    guard textEntryRoles.contains(role) else {
      return borrowed() ?? inner()
    }
    return placeholder ?? borrowed()
  }

  /// The first text a few levels inside `root`: a clickable `<div>`'s words,
  /// or a row's first cell (Music's "Songs", a Finder file's name, a message's
  /// sender). Text before any title, and never an image's: a Music sidebar
  /// row's icon is an `AXImage` described by its symbol's name ("radio",
  /// "pin"), which comes before the row's words. A row's text field counts —
  /// a Finder name cell is one — since it's the row's name, not something
  /// typed. `text` is read only for a static text or that field.
  static func firstText<Node>(
    under root: Node,
    children: (Node) -> [Node],
    role: (Node) -> String?,
    text: (Node) -> String?,
    title: (Node) -> String?,
    limit: Int = 12,
    shouldStop: () -> Bool = { false }
  ) -> String? {
    var queue = children(root)
    var index = 0
    var found: String?
    while index < queue.count, index < limit, !shouldStop() {
      let node = queue[index]
      index += 1
      let kind = role(node)
      if kind == "AXStaticText" || kind == "AXTextField", let words = text(node) {
        return words
      }
      if kind != "AXImage", found == nil { found = title(node) }
      queue += children(node)
    }
    return found
  }
}
