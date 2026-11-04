import CoreFoundation

/// What a screen read needs of one element of a window's tree: the
/// Accessibility node it reads live (`AXRead.Node`), or one recorded from a
/// real app and replayed in a test (`Tests/ScreenTrees`). Everything here is
/// asked only as the read needs it — a live node pays a round trip for some.
protocol ScreenNode {
  var role: String? { get }
  var subrole: String? { get }
  var title: String? { get }
  /// Its `AXDescription`: an icon button's spoken name.
  var nodeDescription: String? { get }
  var placeholder: String? { get }
  var frame: CGRect? { get }
  /// Whether it takes `AXPress`.
  var isPressable: Bool { get }
  /// Its `AXValue`, asked only where that's a name (`ScreenSnapshot.valueNamedRoles`)
  /// or a row's text inside it — never a text entry's contents.
  var rawValue: String? { get }
  var children: [Self] { get }
  /// The element its `AXTitleUIElement` points at: a web form control's `<label>`.
  var titleElement: Self? { get }
}

/// The screen read's decisions over any `ScreenNode` tree: how a node is
/// listed and named, where the page is, and how the 150 slots are shared
/// between the page and the window around it. The live read
/// (`SystemVoiceCommandPerformer+Screen`) and the recorded-tree tests run
/// this same code, so what the tests list is what a command would see.
enum ScreenRead {
  /// Its value when that's its name, and nil — without asking — otherwise.
  static func nameValue<Node: ScreenNode>(_ node: Node) -> String? {
    guard let role = node.role, ScreenSnapshot.valueNamedRoles.contains(role) else { return nil }
    return node.rawValue
  }

  /// What a user would call it: its title, its description, and for a role
  /// whose value is its name, that value.
  static func labels<Node: ScreenNode>(_ node: Node) -> [String] {
    [node.title, node.nodeDescription, nameValue(node)].compactMap { $0 }
  }

  /// The name a web form control borrows from the `<label>` pointing at it.
  static func borrowedLabel<Node: ScreenNode>(_ node: Node) -> String? {
    node.titleElement.flatMap { labels($0).first }
  }

  /// Its labels, else the one it borrows, else the text inside it.
  static func names<Node: ScreenNode>(_ node: Node, shouldStop: () -> Bool = { false }) -> [String] {
    let own = labels(node)
    if !own.isEmpty { return own }
    return (borrowedLabel(node) ?? firstText(under: node, shouldStop: shouldStop)).map { [$0] } ?? []
  }

  static func firstText<Node: ScreenNode>(under node: Node, shouldStop: () -> Bool) -> String? {
    ScreenSnapshot.firstText(
      under: node, children: \.children, role: \.role, text: \.rawValue,
      title: { $0.title ?? $0.nodeDescription }, shouldStop: shouldStop)
  }

  /// How a snapshot lists the node, or nil to leave it out
  /// (`ScreenSnapshot.listedKind`), and what it's called
  /// (`ScreenSnapshot.label`). `bounds`: the window's frame, or the page's.
  static func describe<Node: ScreenNode>(
    _ node: Node, in bounds: CGRect?, shouldStop: () -> Bool = { false }
  ) -> (kind: String, label: String)? {
    guard let role = node.role,
      let kind = ScreenSnapshot.listedKind(
        role: role, subrole: node.subrole, frame: node.frame, bounds: bounds, pressable: { node.isPressable }),
      let label = ScreenSnapshot.label(
        role: role, own: labels(node), placeholder: node.placeholder, borrowed: { borrowedLabel(node) },
        inner: { firstText(under: node, shouldStop: shouldStop) })
        // A field with no name of any kind is still somewhere to type.
        ?? (ScreenSnapshot.textEntryRoles.contains(role) ? kind : nil)
    else { return nil }
    return (kind, label)
  }

  /// The largest element with `role` under `root`, by area, breadth first,
  /// at most 800 nodes visited. An element with no frame doesn't count.
  static func largest<Node: ScreenNode>(role: String, in root: Node, shouldStop: () -> Bool = { false }) -> Node? {
    var best: (node: Node, area: CGFloat)?
    _ = ScreenSnapshot.entries(
      from: root, children: \.children,
      describe: { node in
        if node.role == role, let frame = node.frame, frame.width * frame.height > best?.area ?? 0 {
          best = (node, frame.width * frame.height)
        }
        return nil
      }, visitLimit: 800, shouldStop: shouldStop)
    return best?.node
  }

  /// One bounded breadth-first walk keeping at most `keep`, `incomplete`
  /// set when it stopped before the end.
  static func walk<Node: ScreenNode>(
    _ root: Node, bounds: CGRect?, keep: Int, skip: (Node) -> Bool = { _ in false }, shouldStop: () -> Bool,
    incomplete: inout Bool
  ) -> [ScreenSnapshot.Entry<Node>] {
    var stopped = false
    let entries = ScreenSnapshot.entries(
      from: root, children: \.children, describe: { describe($0, in: bounds, shouldStop: shouldStop) },
      keepLimit: keep, skip: skip, shouldStop: shouldStop, onIncomplete: { stopped = true })
    incomplete = incomplete || stopped
    return entries
  }

  /// The page walked on its own, up to every slot: a browser's tab strip
  /// and bookmarks bar would otherwise fill the list first.
  static func walkPage<Node: ScreenNode>(
    _ area: Node, window: Node, shouldStop: () -> Bool, incomplete: inout Bool
  ) -> [ScreenSnapshot.Entry<Node>] {
    walk(
      area, bounds: area.frame ?? window.frame, keep: ScreenContext.maxElements, shouldStop: shouldStop,
      incomplete: &incomplete)
  }

  /// The window's listing: the window around the page promised the slots
  /// the page's share leaves (`ScreenSnapshot.webShare`), and the page given
  /// every slot the window doesn't use — VS Code's window is one web area,
  /// and 50 sat empty while its Source Control graph went unlisted
  /// (2026-11-04). `page`: its walk (`walkPage`) and whether that stopped
  /// early. `same`: whether two nodes are one element, to leave the page out
  /// of the window's walk.
  static func listing<Node: ScreenNode>(
    window: Node, webArea: Node?, page: (entries: [ScreenSnapshot.Entry<Node>], incomplete: Bool),
    same: (Node, Node) -> Bool, shouldStop: () -> Bool
  ) -> (entries: [ScreenSnapshot.Entry<Node>], incomplete: Bool) {
    var incomplete = false
    let around = walk(
      window, bounds: window.frame,
      keep: ScreenContext.maxElements - min(page.entries.count, ScreenSnapshot.webShare),
      skip: { node in webArea.map { same(node, $0) } ?? false }, shouldStop: shouldStop, incomplete: &incomplete)
    let kept = Array(page.entries.prefix(ScreenContext.maxElements - around.count))
    return (around + kept, incomplete || page.incomplete || kept.count < page.entries.count)
  }
}
