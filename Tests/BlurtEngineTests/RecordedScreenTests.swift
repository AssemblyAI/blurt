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
    for name in RecordedNode.names {
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

  @Test("the recordings on disk are exactly the ones listed: none unlisted, none missing")
  func everyRecordingOnDisk() throws {
    let files = try FileManager.default.contentsOfDirectory(atPath: RecordedNode.directory.path)
      .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
    #expect(Set(files) == Set(RecordedNode.names))
  }

  @Test("no recording holds real text: every string fake or a kept interface word, no value a user typed")
  func noRealText() throws {
    for name in RecordedNode.names {
      let url = RecordedNode.directory.appendingPathComponent("\(name).json")
      let raw = try String(contentsOf: url, encoding: .utf8)
      // No personal shapes, and only the fields the recorder writes.
      let found = try TestFixtures.audit(
        raw, shapes: TestFixtures.personalShapes + TestFixtures.webShapes, allowedKeys: RecordedNode.keys)
      #expect(found.isEmpty, "\(name): \(found)")
      var problems: [String] = []
      Self.audit(try RecordedNode.load(name), into: &problems)
      #expect(problems.isEmpty, "\(name): \(problems.prefix(5))")
    }
  }

  /// The recorder's fake text, "Lorem 12" — checked without a regex, which
  /// would be compiled again for each of a few thousand strings.
  private static func isFake(_ text: String) -> Bool {
    let number = text.dropFirst("Lorem ".count)
    return text.hasPrefix("Lorem ") && !number.isEmpty && number.allSatisfy(\.isASCII) && number.allSatisfy(\.isNumber)
  }

  private static func audit(_ node: RecordedNode, into problems: inout [String]) {
    for text in [node.title, node.nodeDescription, node.placeholder, node.rawValue].compactMap({ $0 })
    where !isFake(text) && !RecordedNode.keptWords.contains(text) {
      problems.append("real text: \(text)")
    }
    if node.rawValue != nil, !RecordedNode.valueRoles.contains(node.role ?? "") {
      problems.append("a value on \(node.role ?? "no role")")
    }
    for child in node.children { audit(child, into: &problems) }
    if let label = node.label { audit(label, into: &problems) }
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
