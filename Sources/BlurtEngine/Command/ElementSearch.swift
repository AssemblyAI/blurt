/// Finding the element a `press_button` step names in an Accessibility tree,
/// over any node type so the search is tested without one.
enum ElementSearch {
  /// The most elements a search looks at: a busy window (a mail list, a
  /// spreadsheet) can hold tens of thousands, each a round trip to its app.
  static let maxElements = 3_000

  /// The pressable node whose label best matches `name` (`NameMatch`),
  /// visiting breadth first (`ScreenSnapshot.entries`), so of two the same
  /// label the one nearer the window's top level wins. An exact match ends the
  /// search there; `shouldStop` ends it early otherwise (the read's deadline).
  static func best<Node>(
    named name: String,
    from root: Node,
    children: (Node) -> [Node],
    labels: (Node) -> [String],
    pressable: (Node) -> Bool,
    limit: Int = maxElements,
    shouldStop: () -> Bool = { false }
  ) -> Node? {
    let query = NameMatch.normalized(name)
    var exact = false
    // A local function rather than a closure argument: it's the last of two
    // closure arguments, so it can't take the trailing form.
    func stopsEarly() -> Bool { exact || shouldStop() }
    let candidates = ScreenSnapshot.entries(
      from: root,
      children: children,
      describe: { node -> (kind: String, label: String)? in
        // One entry per node: its label that matches best. Labels first — they
        // mostly come from a read already made — and `pressable`, a round trip
        // of its own, only for a node whose name matches at all.
        guard let label = NameMatch.best(for: name, among: labels(node)), pressable(node) else {
          return nil
        }
        exact = exact || NameMatch.normalized(label) == query
        return ("", label)
      },
      visitLimit: limit,
      keepLimit: .max,
      shouldStop: stopsEarly
    )
    guard let label = NameMatch.best(for: name, among: candidates.map(\.label)) else {
      return nil
    }
    return candidates.first { $0.label == label }?.node
  }
}
