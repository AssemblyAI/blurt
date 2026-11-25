/// A selection split around its words: the whitespace it starts and ends with,
/// and what's between. The rewrite gets only the words and the edges are put
/// back around its reply, because the paste replaces the whole highlight — a
/// line triple-clicked with its line break, or an indented one, must keep it,
/// and the reply comes back trimmed (`ReadAloudLLM.reply(from:)`).
struct SelectionEdges: Equatable, Sendable {
  let leading: Substring
  let words: Substring
  let trailing: Substring

  init(_ selection: String) {
    let start = selection.firstIndex { !$0.isWhitespace } ?? selection.endIndex
    let end = selection.lastIndex { !$0.isWhitespace }.map(selection.index(after:)) ?? start
    leading = selection[..<start]
    words = selection[start..<end]
    trailing = selection[end...]
  }

  /// `rewrite` in the selection's place: its edges around it.
  func around(_ rewrite: String) -> String { leading + rewrite + trailing }
}
