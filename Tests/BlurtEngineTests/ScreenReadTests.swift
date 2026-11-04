import CoreGraphics
import Testing

@testable import BlurtEngine

/// A hand-built element: the attributes `ScreenNode` asks for, set directly,
/// so a test builds the three-node tree a rule is about rather than replaying
/// a recorded app. A class, so a tree can hold itself and two compare by `===`.
private final class TinyNode: ScreenNode {
  let role: String?
  let subrole: String? = nil
  let title: String?
  let nodeDescription: String?
  let placeholder: String?
  let frame: CGRect?
  let isPressable: Bool
  let rawValue: String?
  let children: [TinyNode]
  let titleElement: TinyNode?

  init(
    _ role: String?, title: String? = nil, description: String? = nil, value: String? = nil,
    placeholder: String? = nil, frame: CGRect? = nil, pressable: Bool = false, label: TinyNode? = nil,
    children: [TinyNode] = []
  ) {
    self.role = role
    self.title = title
    nodeDescription = description
    self.placeholder = placeholder
    self.frame = frame
    isPressable = pressable
    rawValue = value
    self.children = children
    titleElement = label
  }

  static func button(_ title: String) -> TinyNode { TinyNode("AXButton", title: title) }
  static func text(_ words: String) -> TinyNode { TinyNode("AXStaticText", value: words) }
}

/// `ScreenRead`'s decisions over a tree — how a node is named, how a walk
/// reports stopping short, how the slots are shared with a page — and the
/// `ScreenSnapshot` naming rules under them.
@Suite("ScreenRead · naming and listing")
struct ScreenReadTests {
  private func entries(_ labels: [String]) -> [ScreenSnapshot.Entry<TinyNode>] {
    labels.map { ScreenSnapshot.Entry(node: TinyNode.button($0), kind: "button", label: $0) }
  }

  @Test("a web control borrows its <label>'s title, ahead of that label's description")
  func borrowsTheLabelsTitle() {
    let label = TinyNode("AXStaticText", title: "Email", description: "Your work address")
    let field = TinyNode("AXTextField", label: label)
    #expect(ScreenRead.borrowedLabel(field) == "Email")
    #expect(ScreenRead.names(field) == ["Email"])
  }

  @Test("a node with no name of its own is named by the text inside it")
  func namesFallBackToInnerText() {
    let row = TinyNode("AXRow", children: [TinyNode("AXImage", description: "pin"), .text("Songs")])
    #expect(ScreenRead.names(row) == ["Songs"])
    #expect(
      ScreenRead.names(TinyNode("AXButton", title: "Play", description: "Play button")) == ["Play", "Play button"])
  }

  @Test("an untitled button is listed under the words inside it")
  func describeReadsInnerText() {
    let send = TinyNode("AXButton", children: [.text("Send")])
    let described = ScreenRead.describe(send, in: nil)
    #expect(described?.kind == "button")
    #expect(described?.label == "Send")
    // A field with no name of any kind still lists, under its kind.
    #expect(ScreenRead.describe(TinyNode("AXTextField"), in: nil)?.label == "text field")
    #expect(ScreenRead.describe(TinyNode("AXButton"), in: nil) == nil)
  }

  @Test("the largest element of a role wins, and one with no frame doesn't count")
  func largest() {
    let small = TinyNode("AXWebArea", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    let big = TinyNode("AXWebArea", frame: CGRect(x: 0, y: 0, width: 100, height: 50))
    let window = TinyNode(
      "AXWindow", children: [small, TinyNode("AXWebArea"), TinyNode("AXGroup", children: [big])])
    #expect(ScreenRead.largest(role: "AXWebArea", in: window) === big)
    #expect(ScreenRead.largest(role: "AXWebArea", in: TinyNode("AXWindow", children: [TinyNode("AXWebArea")])) == nil)
  }

  @Test("a walk that reaches the end is complete; one cut short by its cap says so, and never un-says it")
  func walkReportsStoppingShort() {
    let window = TinyNode("AXWindow", children: [.button("One"), .button("Two"), .button("Three")])
    var incomplete = false
    let all = ScreenRead.walk(window, bounds: nil, keep: 5, shouldStop: { false }, incomplete: &incomplete)
    #expect(all.map(\.label) == ["One", "Two", "Three"])
    #expect(!incomplete)

    let first = ScreenRead.walk(window, bounds: nil, keep: 1, shouldStop: { false }, incomplete: &incomplete)
    #expect(first.map(\.label) == ["One"])
    #expect(incomplete)

    // An earlier walk's stop isn't cleared by a later one that finished.
    _ = ScreenRead.walk(window, bounds: nil, keep: 5, shouldStop: { false }, incomplete: &incomplete)
    #expect(incomplete)
  }

  @Test("a window with no page listed whole is complete")
  func listingCompleteWithoutPage() {
    let window = TinyNode("AXWindow", children: [.button("Back"), .button("Forward")])
    let listing = ScreenRead.listing(
      window: window, webArea: nil, page: ([], false), same: { $0 === $1 }, shouldStop: { false })
    #expect(listing.entries.map(\.label) == ["Back", "Forward"])
    #expect(!listing.incomplete)
  }

  @Test("with no page, the window has every slot, not only what a page's share leaves")
  func listingWindowTakesEverySlotWithoutPage() {
    let buttons = (1...60).map { TinyNode.button("B\($0)") }
    let listing = ScreenRead.listing(
      window: TinyNode("AXWindow", children: buttons), webArea: nil, page: ([], false), same: { $0 === $1 },
      shouldStop: { false })
    #expect(listing.entries.count == 60)
    #expect(!listing.incomplete)
  }

  @Test("a page whose own walk stopped early leaves the listing incomplete, all of it kept")
  func listingCarriesThePagesStop() {
    let window = TinyNode("AXWindow", children: [.button("Reload")])
    let listing = ScreenRead.listing(
      window: window, webArea: nil, page: (entries(["Sign in"]), true), same: { $0 === $1 }, shouldStop: { false })
    #expect(listing.entries.map(\.label) == ["Reload", "Sign in"])
    #expect(listing.incomplete)
  }

  @Test("the page is skipped in the window's walk, and a page cut to fit the slots marks the listing incomplete")
  func listingSharesSlotsWithThePage() {
    let page = TinyNode("AXWebArea", children: [.button("Inside")])
    let window = TinyNode("AXWindow", children: (1...20).map { TinyNode.button("Tab \($0)") } + [page])
    let pageEntries = entries((1...140).map { "Link \($0)" })
    let listing = ScreenRead.listing(
      window: window, webArea: page, page: (pageEntries, false), same: { $0 === $1 }, shouldStop: { false })
    #expect(listing.entries.count == ScreenContext.maxElements)
    #expect(listing.entries.prefix(20).allSatisfy { $0.label.hasPrefix("Tab ") })
    #expect(!listing.entries.contains { $0.label == "Inside" })
    #expect(listing.incomplete)
  }

  @Test("a listed node goes by its first own label, its title before its description")
  func labelTakesTheFirstOwn() {
    let label = ScreenSnapshot.label(
      role: "AXButton", own: ["Reply", "Reply to sender"], placeholder: nil, borrowed: { nil }, inner: { nil })
    #expect(label == "Reply")
  }

  @Test("the first text inside a node is its static text's words, past an icon")
  func firstTextFindsStaticText() {
    let row = TinyNode("AXRow", children: [TinyNode("AXImage", description: "radio"), .text("Radio")])
    let found = ScreenSnapshot.firstText(
      under: row, children: \.children, role: \.role, text: \.rawValue, title: { $0.title ?? $0.nodeDescription })
    #expect(found == "Radio")
  }
}
