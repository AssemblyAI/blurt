import Foundation

@testable import BlurtEngine

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

  /// The keys a recording is written with — and the only ones it may hold.
  static var keys: Set<String> { Set(CodingKeys.allCases.map(\.stringValue)) }

  private enum CodingKeys: String, CodingKey, CaseIterable {
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
    return ScreenContext(
      appName: recordings.first { $0.name == name }.map { $0.appName ?? $0.app } ?? name, elements: elements,
      incomplete: result.incomplete)
  }

  /// The only real strings a recording may keep: interface words that
  /// name no person, channel, file or message. The recorder fakes every
  /// other string, and `RecordedScreenTests.noRealText` holds it to that.
  static let keptWords: Set<String> = [
    "Search", "Send", "Reply", "Close", "Back", "Forward", "Home", "Activity", "Settings", "Favorites",
    "Inbox", "Sent", "Drafts", "Junk", "Archive", "Trash", "Downloads", "Documents", "Desktop", "Recents",
    "Applications", "Explorer", "Source Control", "Run and Debug", "Extensions", "New", "Share", "Edit",
    "File", "View", "Help", "Window", "Go", "Format", "Insert", "Tools", "Unreads", "Threads", "Later",
    "DMs", "Direct messages", "Channels", "All Items", "Watchtower", "Profile", "Developer", "sidebar",
  ]

  /// The roles a recording may carry a value for: where it's a name, or a
  /// row's text — never anything a user types into.
  static let valueRoles = ScreenSnapshot.valueNamedRoles

  /// One recorded app: its file in `Tests/ScreenTrees`, the app `open_app`
  /// opens to record it, the name the screen read gives it when that differs,
  /// and what to press first so it's recorded in the view its tests expect
  /// (Slack's Home, not Activity).
  struct Recording {
    let name: String
    let app: String
    var appName: String?
    var start: String?
  }

  /// Every recording — the recorder's list and the tests', in one place;
  /// `RecordedScreenTests.everyRecordingOnDisk` holds the folder to it.
  static let recordings = [
    Recording(name: "1Password", app: "1Password"),
    Recording(name: "Chrome", app: "Google Chrome"),
    Recording(name: "Code", app: "Visual Studio Code", appName: "Code"),
    Recording(name: "Finder", app: "Finder"),
    Recording(name: "Mail", app: "Mail"),
    Recording(name: "Obsidian", app: "Obsidian"),
    Recording(name: "Safari", app: "Safari"),
    Recording(name: "Slack", app: "Slack", start: "Home"),
  ]

  static var names: [String] { recordings.map(\.name) }

  static let directory = TestFixtures.url("Tests/ScreenTrees")

  static func load(_ name: String) throws -> RecordedNode {
    try JSONDecoder().decode(
      RecordedNode.self, from: Data(contentsOf: directory.appendingPathComponent("\(name).json")))
  }
}
