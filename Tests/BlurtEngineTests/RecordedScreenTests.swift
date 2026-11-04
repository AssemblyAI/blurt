import Foundation
import Testing

@testable import BlurtEngine

/// Real apps' windows, recorded once (`ScreenTreeRecorder`) and replayed here
/// through the screen read's own code (`ScreenRead`), so what each lists is
/// checked with no app running. Every string in a recording is replaced by a
/// fake one ("Lorem 12") except a short list of generic interface words, so a
/// fixture carries an app's structure, never its content.
@Suite("Recorded screens")
struct RecordedScreenTests {
  /// One recording's listing, as a command over that window would see it.
  private func listing(_ name: String) throws -> [(kind: String, label: String)] {
    try RecordedNode.context(name).elements.map { ($0.kind, $0.label) }
  }

  private func kinds(_ listed: [(kind: String, label: String)]) -> [String: Int] {
    Dictionary(grouping: listed, by: \.kind).mapValues(\.count)
  }

  @Test("every recording lists at most 150 elements, each named, and never a password field")
  func invariants() throws {
    for name in RecordedNode.recordings {
      let listed = try listing(name)
      #expect(!listed.isEmpty, "\(name) lists nothing")
      #expect(listed.count <= ScreenContext.maxElements, "\(name)")
      #expect(listed.allSatisfy { !$0.label.isEmpty }, "\(name) lists an unnamed element")
    }
  }

  @Test("a browser's tab strip and toolbar never crowd out the page: Chrome and Safari list mostly the page's links")
  func browsersListThePage() throws {
    for name in ["Chrome", "Safari"] {
      let listed = try listing(name)
      #expect(listed.count == ScreenContext.maxElements, "\(name)")
      // The window around the page is held to what the page's share leaves.
      #expect(listed.count - kinds(listed)["link", default: 0] <= ScreenContext.maxElements - 50, "\(name)")
    }
  }

  @Test("Obsidian, an Electron app, lists its clickable panes and its editor")
  func obsidian() throws {
    let found = kinds(try listing("Obsidian"))
    #expect(found["clickable", default: 0] >= 10)
    #expect(found["text area", default: 0] >= 1)
  }

  @Test("1Password's items — menu items named only by their value — are listed")
  func onePasswordItems() throws {
    #expect(kinds(try listing("1Password"))["menu item", default: 0] >= 5)
  }

  @Test("VS Code's one web area gets the slots its window doesn't use, past the page's share")
  func vsCodeUsesEverySlot() throws {
    #expect(try listing("Code").count > ScreenSnapshot.webShare)
  }

  @Test("Slack's sidebar channels are listed as rows")
  func slackSidebar() throws {
    #expect(kinds(try listing("Slack"))["row", default: 0] >= 5)
  }

  @Test("Mail's mailboxes are listed, Inbox by name")
  func mailMailboxes() throws {
    let listed = try listing("Mail")
    #expect(listed.contains { $0.label == "Inbox" })
  }

  @Test("Finder's search — a button with the search-field subrole — is listed as a search field")
  func finderSearch() throws {
    #expect(try listing("Finder").contains { $0.kind == "search field" })
  }
}

/// A recorded element: the attributes `ScreenNode` asks for, and its children.
/// A class, so a tree can hold itself and a test can tell two apart (`===`).
final class RecordedNode: ScreenNode, Codable {
  let role: String?
  let subrole: String?
  let title: String?
  let nodeDescription: String?
  let placeholder: String?
  /// Its frame as `[x, y, width, height]`; empty when it has none.
  let rect: [Double]
  let pressable: Bool?
  let rawValue: String?
  let children: [RecordedNode]
  let label: RecordedNode?

  var frame: CGRect? { rect.count == 4 ? CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) : nil }
  var isPressable: Bool { pressable ?? false }
  var titleElement: RecordedNode? { label }

  private enum CodingKeys: String, CodingKey {
    case role = "r"
    case subrole = "s"
    case title = "t"
    case nodeDescription = "d"
    case placeholder = "p"
    case rect = "f"
    case pressable = "a"
    case rawValue = "v"
    case children = "c"
    case label = "l"
  }

  init(
    role: String?, subrole: String?, title: String?, nodeDescription: String?, placeholder: String?,
    frame: CGRect?, pressable: Bool, rawValue: String?, children: [RecordedNode], label: RecordedNode?
  ) {
    self.role = role
    self.subrole = subrole
    self.title = title
    self.nodeDescription = nodeDescription
    self.placeholder = placeholder
    // To a tenth of a point: the walk compares frames, never finer.
    let rounded: (CGFloat) -> Double = { (Double($0) * 10).rounded() / 10 }
    rect = frame.map { [rounded($0.minX), rounded($0.minY), rounded($0.width), rounded($0.height)] } ?? []
    self.pressable = pressable ? true : nil
    self.rawValue = rawValue
    self.children = children
    self.label = label
  }

  required init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    role = try container.decodeIfPresent(String.self, forKey: .role)
    subrole = try container.decodeIfPresent(String.self, forKey: .subrole)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    nodeDescription = try container.decodeIfPresent(String.self, forKey: .nodeDescription)
    placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
    rect = try container.decodeIfPresent([Double].self, forKey: .rect) ?? []
    pressable = try container.decodeIfPresent(Bool.self, forKey: .pressable)
    rawValue = try container.decodeIfPresent(String.self, forKey: .rawValue)
    children = try container.decodeIfPresent([RecordedNode].self, forKey: .children) ?? []
    label = try container.decodeIfPresent(RecordedNode.self, forKey: .label)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(role, forKey: .role)
    try container.encodeIfPresent(subrole, forKey: .subrole)
    try container.encodeIfPresent(title, forKey: .title)
    try container.encodeIfPresent(nodeDescription, forKey: .nodeDescription)
    try container.encodeIfPresent(placeholder, forKey: .placeholder)
    if !rect.isEmpty { try container.encode(rect, forKey: .rect) }
    try container.encodeIfPresent(pressable, forKey: .pressable)
    try container.encodeIfPresent(rawValue, forKey: .rawValue)
    if !children.isEmpty { try container.encode(children, forKey: .children) }
    try container.encodeIfPresent(label, forKey: .label)
  }

  /// A recording as the planner would be shown it: the listing the screen
  /// read's own code (`ScreenRead`) makes of it, under the app's name.
  static func context(_ name: String) throws -> ScreenContext {
    let window = try load(name)
    let webArea = ScreenRead.largest(role: "AXWebArea", in: window)
    var pageIncomplete = false
    let page =
      webArea.map { ScreenRead.walkPage($0, window: window, shouldStop: { false }, incomplete: &pageIncomplete) } ?? []
    let result = ScreenRead.listing(
      window: window, webArea: webArea, page: (page, pageIncomplete), same: { $0 === $1 }, shouldStop: { false })
    let elements = result.entries.enumerated().map { ScreenContext.Element(id: $0 + 1, kind: $1.kind, label: $1.label) }
    return ScreenContext(appName: appNames[name] ?? name, elements: elements, incomplete: result.incomplete)
  }

  /// Each recording's app, as the screen read names it.
  static let appNames = [
    "1Password": "1Password", "Chrome": "Google Chrome", "Code": "Code", "Finder": "Finder", "Mail": "Mail",
    "Obsidian": "Obsidian", "Safari": "Safari", "Slack": "Slack",
  ]

  /// The apps recorded, by file name in `Tests/ScreenTrees`.
  static let recordings = ["1Password", "Chrome", "Code", "Finder", "Mail", "Obsidian", "Safari", "Slack"]

  static let directory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ScreenTrees")

  static func load(_ name: String) throws -> RecordedNode {
    try JSONDecoder().decode(
      RecordedNode.self, from: Data(contentsOf: directory.appendingPathComponent("\(name).json")))
  }
}
