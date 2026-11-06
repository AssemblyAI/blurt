import CoreGraphics
import Testing

@testable import BlurtEngine

/// The decisions the real performer makes acting on an element, driven with
/// fake Accessibility reads and writes: what's pressed, clicked, selected,
/// and where the pointer ends up.
@Suite("ElementActions")
struct ElementActionsTests {
  /// A fake element: what each call did, and what each read answers.
  private final class Element: @unchecked Sendable {
    var calls: [String] = []
    var takesPress = true
    var pressChanges = true
    var takesFocus = true
    var clickFocuses = true
    var focused = false
    var title = "Inbox"

    var fingerprint: PressFingerprint {
      calls.append("read")
      return PressFingerprint(focusedElement: nil, windowTitle: title, value: nil, onScreen: true)
    }

    func press() -> Bool {
      calls.append("press")
      if takesPress, pressChanges { title = "Reply" }
      return takesPress
    }

    func click() {
      calls.append("click")
      if clickFocuses { focused = true }
    }
  }

  private func press(_ element: Element, checked: Bool = true) async throws -> String {
    try await ElementActions.press(
      fingerprint: checked ? { element.fingerprint } : nil, press: { element.press() },
      settle: { element.calls.append("settle") }, click: { element.click() })
  }

  @Test("a press that changes something is the whole step: no click")
  func pressWorks() async throws {
    let element = Element()
    #expect(try await press(element) == "AXPress")
    #expect(element.calls == ["read", "press", "settle", "read"])
  }

  @Test("a press the element refuses is a click instead, without waiting to see")
  func pressRefused() async throws {
    let element = Element()
    element.takesPress = false
    #expect(try await press(element) == "click: AXPress refused")
    #expect(element.calls == ["read", "press", "click"])
  }

  @Test("a checked press that reports success and changes nothing is clicked as well — once")
  func pressIgnored() async throws {
    let element = Element()
    element.pressChanges = false
    #expect(try await press(element) == "AXPress, then click: nothing visibly changed")
    #expect(element.calls.filter { $0 == "click" }.count == 1)
  }

  @Test("in a native app a press's success is trusted: Calculator's 6 goes in once, not twice")
  func nativePressTrusted() async throws {
    let element = Element()
    element.pressChanges = false
    #expect(try await press(element, checked: false) == "AXPress")
    #expect(element.calls == ["press"])
    // Refused, it's still clicked: the click is for an element with no action.
    element.takesPress = false
    #expect(try await press(element, checked: false) == "click: AXPress refused")
  }

  @Test("the same check serves a selection: a row that takes AXSelected and opens nothing is clicked")
  func selectionChecked() async throws {
    let element = Element()
    element.pressChanges = false
    let how = try await ElementActions.press(
      "AXSelected", fingerprint: { element.fingerprint }, press: { element.press() }, settle: {},
      click: { element.click() })
    #expect(how == "AXSelected, then click: nothing visibly changed")
  }

  @Test("a command cancelled while a press settles clicks nothing")
  func cancelledPress() async throws {
    let element = Element()
    element.pressChanges = false
    await #expect(throws: CancellationError.self) {
      try await ElementActions.press(
        fingerprint: { element.fingerprint }, press: { element.press() },
        settle: { throw CancellationError() }, click: { element.click() })
    }
    #expect(!element.calls.contains("click"))
  }

  private func focus(_ element: Element, singleLine: Bool = true) async throws -> String {
    try await ElementActions.focus(
      singleLine: singleLine,
      setFocus: {
        element.calls.append("focus")
        if element.takesFocus { element.focused = true }
      },
      isFocused: { element.focused }, click: { element.click() },
      selectAll: {
        element.calls.append("select")
        return "selected 18 characters"
      })
  }

  @Test("a field that takes focus has its contents selected, so typing replaces them")
  func focusTaken() async throws {
    let element = Element()
    #expect(try await focus(element) == "AX focus; selected 18 characters")
    #expect(element.calls == ["focus", "select"])
  }

  @Test("a field that ignores focus is clicked, then selected once it's focused")
  func focusByClick() async throws {
    let element = Element()
    element.takesFocus = false
    #expect(try await focus(element) == "click: AX focus not taken; selected 18 characters")
    #expect(element.calls == ["focus", "click", "select"])
  }

  @Test("nothing is selected unless the field is confirmed focused: the selection would land elsewhere")
  func neverFocused() async throws {
    let element = Element()
    element.takesFocus = false
    element.clickFocuses = false
    #expect(try await focus(element) == "click: AX focus not taken; still not focused, nothing selected")
    #expect(!element.calls.contains("select"))
  }

  @Test("a text area keeps its cursor: a typed step adds to what's there")
  func textArea() async throws {
    let element = Element()
    #expect(try await focus(element, singleLine: false) == "AX focus; a text area keeps its cursor")
    #expect(!element.calls.contains("select"))
  }

  /// A menu as Accessibility nests it: a bar item's entries inside one menu.
  private struct Menu {
    let title: String?
    var children: [Menu] = []
  }

  private let bar = Menu(
    title: nil,
    children: [
      Menu(
        title: "File",
        children: [
          Menu(
            title: nil,
            children: [
              Menu(title: "New Window"),
              Menu(title: "Export To", children: [Menu(title: nil, children: [Menu(title: "PDF…")])]),
              Menu(title: "Move to Trash"),
            ])
        ])
    ])

  private func item(_ path: [String]) throws -> Menu {
    try ElementActions.menuItem(
      path, from: bar, entries: { $0.children.flatMap { $0.title == nil ? $0.children : [$0] } }, title: \.title)
  }

  @Test("a menu path is walked through each menu's entries, each title matched loosely")
  func menuWalk() throws {
    #expect(try item(["File", "New Window"]).title == "New Window")
    #expect(try item(["file", "export to", "pdf"]).title == "PDF…")
    #expect(throws: VoiceCommandError.menuItemNotFound(["File", "Print"])) { try item(["File", "Print"]) }
    #expect(throws: VoiceCommandError.menuItemNotFound(["Edit"])) { try item(["Edit"]) }
  }

  @Test("a wrong path whose last title is right finds that one item, wherever it is")
  func menuAnywhere() throws {
    func anywhere(_ name: String) throws -> Menu? {
      try ElementActions.menuItem(
        named: name, from: bar, entries: { $0.children.flatMap { $0.title == nil ? $0.children : [$0] } },
        title: \.title)
    }
    #expect(try anywhere("pdf…")?.title == "PDF…")
    #expect(try anywhere("Print") == nil)
    #expect(throws: VoiceCommandError.refused("choose Move to Trash")) { try anywhere("Move to Trash") }
  }

  @Test("a destructive menu item is refused by the title it matched, not only the title asked for")
  func menuDestructive() throws {
    #expect(throws: VoiceCommandError.refused("choose File › move to trash")) {
      try item(["File", "move to trash"])
    }
  }

  @Test("two bar items with one title: the path walks into the first, as the menu bar lists them")
  func menuDuplicateTitle() throws {
    let twoViews = Menu(
      title: nil,
      children: [
        Menu(title: "View", children: [Menu(title: nil, children: [Menu(title: "Zoom In")])]),
        Menu(title: "View", children: [Menu(title: nil, children: [Menu(title: "Sidebar")])]),
      ])
    let found = try ElementActions.menuItem(
      ["View", "Zoom In"], from: twoViews, entries: { $0.children.flatMap { $0.title == nil ? $0.children : [$0] } },
      title: \.title)
    #expect(found.title == "Zoom In")
  }

  @Test("the pointer goes home however the click ends: done, thrown, or cancelled during the beat")
  func pointerReturns() async throws {
    let home = CGPoint(x: 5, y: 5)
    let target = CGPoint(x: 100, y: 200)
    func visit(body: () throws -> Void, beat: @escaping () async throws -> Void) async -> [CGPoint] {
      var warps: [CGPoint] = []
      try? await ElementActions.withPointer(
        at: target, home: home, warp: { warps.append($0) }, beat: beat, body)
      return warps
    }
    #expect(await visit(body: {}, beat: {}) == [target, home])
    #expect(await visit(body: { throw VoiceCommandError.couldNotPerform("click there") }, beat: {}) == [target, home])
    #expect(await visit(body: {}, beat: { throw CancellationError() }) == [target, home])
  }
}
