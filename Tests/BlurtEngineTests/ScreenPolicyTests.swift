import CoreGraphics
import Testing

@testable import BlurtEngine

/// The rules for what a screen read lists and how it names it: pure, apart
/// from the Accessibility calls the shell makes for them.
@Suite("ScreenSnapshot policy")
struct ScreenPolicyTests {
  @Test("a node is listed by its kind only when on screen, and a group or text only when it takes a press")
  func listedKind() {
    let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    let inside = CGRect(x: 10, y: 10, width: 50, height: 20)
    var asked = 0
    func pressable(_ answer: Bool) -> () -> Bool {
      {
        asked += 1
        return answer
      }
    }
    #expect(
      ScreenSnapshot.listedKind(
        role: "AXButton", subrole: nil, frame: inside, bounds: window, pressable: pressable(false)) == "button")
    #expect(
      ScreenSnapshot.listedKind(
        role: "AXGroup", subrole: nil, frame: inside, bounds: window, pressable: pressable(true)) == "clickable")
    #expect(
      ScreenSnapshot.listedKind(
        role: "AXGroup", subrole: nil, frame: inside, bounds: window, pressable: pressable(false)) == nil)
    // Off screen: settled before the round trip `pressable` costs.
    let before = asked
    #expect(
      ScreenSnapshot.listedKind(
        role: "AXGroup", subrole: nil, frame: CGRect(x: 10, y: 2_000, width: 50, height: 20), bounds: window,
        pressable: pressable(true)) == nil)
    #expect(asked == before)
    // A password field is never listed, by role or by subrole.
    #expect(ScreenSnapshot.kind(role: "AXSecureTextField", subrole: nil) == nil)
    #expect(ScreenSnapshot.kind(role: "AXTextField", subrole: "AXSecureTextField") == nil)
  }

  @Test(
    "a text entry goes by its placeholder, borrowed label or kind — never asked for its text; anything else by what's inside"
  )
  func labelChoice() {
    #expect(
      ScreenSnapshot.label(
        role: "AXButton", own: ["Send"], placeholder: nil, borrowed: { nil }, inner: { nil }) == "Send")
    #expect(
      ScreenSnapshot.label(
        role: "AXTextField", own: [], placeholder: "Search", borrowed: { "Name" },
        inner: { "typed" })
        == "Search")
    #expect(
      ScreenSnapshot.label(
        role: "AXTextArea", own: [], placeholder: nil, borrowed: { nil }, inner: { "typed" })
        // Nothing to name it by: never its contents (`inner`), and its kind
        // is `describe`'s to add.
        == nil)
    #expect(
      ScreenSnapshot.label(role: "AXRow", own: [], placeholder: nil, borrowed: { nil }, inner: { "Songs" })
        == "Songs")
    #expect(
      ScreenSnapshot.label(role: "AXRow", own: [], placeholder: nil, borrowed: { nil }, inner: { nil })
        == nil)
    // One list decides both what may be focused and whose contents go unread.
    #expect(ScreenSnapshot.textEntryRoles.isSuperset(of: ScreenSnapshot.singleLineEntryRoles))
    #expect(ScreenSnapshot.valueNamedRoles.isDisjoint(with: ScreenSnapshot.textEntryRoles))
  }

  @Test("a row's name is the text inside it, never its icon's symbol, and the lookup stops when told")
  func firstText() {
    struct Cell {
      let role: String
      var text: String?
      var title: String?
      var children: [Cell] = []
    }
    let row = Cell(
      role: "AXRow",
      children: [
        Cell(
          role: "AXCell",
          children: [Cell(role: "AXImage", title: "radio"), Cell(role: "AXStaticText", text: "Radio")])
      ])
    func find(_ root: Cell, stop: @escaping () -> Bool = { false }) -> String? {
      ScreenSnapshot.firstText(
        under: root, children: \.children, role: { $0.role }, text: \.text, title: \.title, shouldStop: stop)
    }
    #expect(find(row) == "Radio")
    #expect(find(Cell(role: "AXRow", children: [Cell(role: "AXImage", title: "pin")])) == nil)
    #expect(find(Cell(role: "AXRow", children: [Cell(role: "AXGroup", title: "Pins")])) == "Pins")
    #expect(find(row, stop: { true }) == nil)
  }
}
