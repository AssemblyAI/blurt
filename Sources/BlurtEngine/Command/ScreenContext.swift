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

  /// The most elements one snapshot lists: enough for a mail window's
  /// toolbar, sidebar and message actions, and a bounded prompt.
  static let maxElements = 150
  /// The most of a label the planner is shown.
  static let maxLabelCharacters = 80

  /// The longest label the prompt carries, in characters: VS Code names a
  /// Source Control graph row by its whole commit message, 700 characters
  /// and more (2026-11-04). The start is what a spoken command names.
  static let labelCap = 120

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

  /// `label` cut to `labelCap`, an ellipsis marking the cut.
  static func shortened(_ label: String) -> String {
    label.count <= labelCap ? label : String(label.prefix(labelCap - 1)) + "…"
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
      if flattened.contains(scalar) || scalar.properties.generalCategory == .format {
        return " "
      }
      switch scalar {
      case "\"":
        return "'"

      case "<":
        return "‹"

      case ">":
        return "›"

      default:
        return String(scalar)
      }
    }
    return String(scalars.joined().prefix(maxLabelCharacters))
  }

  /// The snapshot as the planner's user turn shows it, before the command.
  /// Nil with no app in front. `fence`: the request's random code, on the
  /// window block's opening and closing tags (Peekaboo's datamarking), so the
  /// block's edges are ones no screen text could have written.
  func promptText(fence: String) -> String? {
    guard let appName else {
      return nil
    }
    var text = "<frontmost_app>\n\(Self.quoted(appName))\n</frontmost_app>"
    guard windowTitle != nil || !elements.isEmpty else {
      return text
    }
    let title = windowTitle.map { " title=\"\(Self.quoted($0))\"" } ?? ""
    var lines = elements.map { "[\($0.id)] \($0.kind) \"\(Self.quoted(Self.shortened($0.label)))\"" }
    if incomplete { lines.append("(More is on screen than is listed: an element not listed may still be there.)") }
    text += "\n\n<window fence=\"\(fence)\"\(title)>\n" + lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    return text + "</window fence=\"\(fence)\">"
  }
}
