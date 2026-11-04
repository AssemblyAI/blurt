import Foundation
import Testing

@testable import BlurtEngine

/// Reading a planner reply into steps: what each action needs, and the checks
/// that refuse a plan — or put a step into the form Blurt carries out best —
/// before any of it runs.
@Suite("VoiceCommandStep · parse")
struct VoiceCommandParseTests {
  private func steps(_ json: String, listed: [ScreenContext.Element] = []) throws -> [VoiceCommandStep] {
    try VoiceCommandStep.steps(fromReply: #"{"steps": ["# + json + "]}", maxSteps: 10, listed: listed)
  }

  @Test("the control steps parse, and every one naming an element is checked against the snapshot")
  func controlSteps() throws {
    let listed: [ScreenContext.Element] = [
      .init(id: 1, kind: "row", label: "Songs"), .init(id: 2, kind: "button", label: "Share"),
      .init(id: 3, kind: "slider", label: "Volume"),
    ]
    func steps(_ json: String) throws -> [VoiceCommandStep] { try self.steps(json, listed: listed) }
    #expect(try steps(#"{"action": "select", "element": 1}"#) == [.select(1)])
    #expect(try steps(#"{"action": "show_menu", "element": 2}"#) == [.showMenu(2)])
    #expect(try steps(#"{"action": "set_value", "element": 3, "value": 40}"#) == [.setValue(element: 3, value: "40")])
    #expect(try steps(#"{"action": "increment", "element": 3}"#) == [.increment(3)])
    #expect(try steps(#"{"action": "decrement", "element": 3}"#) == [.decrement(3)])
    #expect(try steps(#"{"action": "scroll", "direction": "down"}"#) == [.scroll(.down, element: nil)])
    #expect(try steps(#"{"action": "scroll", "direction": "up", "element": 2}"#) == [.scroll(.up, element: 2)])
    #expect(try steps(#"{"action": "window", "operation": "left_half"}"#) == [.window(.leftHalf)])
    #expect(throws: VoiceCommandError.unknownElement(9)) { try steps(#"{"action": "select", "element": 9}"#) }
    #expect(throws: VoiceCommandError.unknownElement(9)) {
      try steps(#"{"action": "scroll", "direction": "down", "element": 9}"#)
    }
    #expect(throws: VoiceCommandError.malformedReply) { try steps(#"{"action": "scroll", "direction": "sideways"}"#) }
    #expect(throws: VoiceCommandError.unsupportedAction("window")) {
      try steps(#"{"action": "window", "operation": "spin"}"#)
    }
    #expect(throws: VoiceCommandError.malformedReply) { try steps(#"{"action": "set_value", "element": 3}"#) }
    // An element of a kind the action doesn't take: refused before anything
    // runs, and asked for again.
    #expect(throws: VoiceCommandError.wrongKind(action: "select", id: 2, kind: "button")) {
      try steps(#"{"action": "select", "element": 2}"#)
    }
    #expect(throws: VoiceCommandError.wrongKind(action: "set_value", id: 1, kind: "row")) {
      try steps(#"{"action": "set_value", "element": 1, "value": 0}"#)
    }
    #expect(throws: VoiceCommandError.wrongKind(action: "focus", id: 2, kind: "button")) {
      try steps(#"{"action": "focus", "element": 2}"#)
    }
    #expect(VoiceCommandError.wrongKind(action: "select", id: 2, kind: "button").isRetryable)
    // The retry for words put in a field by set_value says how to type there.
    #expect(
      VoiceCommandError.wrongKind(action: "set_value", id: 3, kind: "search field").errorDescription?
        .hasSuffix("To put words in a search field, focus it, then type them.") == true)
  }

  @Test("a plan that would press something destructive is refused whole, before its first step runs")
  func destructiveRefusedUpFront() throws {
    let listed: [ScreenContext.Element] = [
      .init(id: 1, kind: "button", label: "Delete"), .init(id: 2, kind: "row", label: "Lunch"),
    ]
    func steps(_ json: String) throws -> [VoiceCommandStep] { try self.steps(json, listed: listed) }
    #expect(throws: VoiceCommandError.refused("press Delete")) {
      try steps(#"{"action": "shortcut", "keys": "cmd+a"}, {"action": "press", "element": 1}"#)
    }
    // A select of a destructive row too, before the steps ahead of it run.
    let trashRow: [ScreenContext.Element] = [.init(id: 9, kind: "row", label: "Trash")]
    #expect(throws: VoiceCommandError.refused("press Trash")) {
      try self.steps(#"{"action": "type", "text": "x"}, {"action": "select", "element": 9}"#, listed: trashRow)
    }
    #expect(throws: VoiceCommandError.refused("press Move to Trash")) {
      try steps(#"{"action": "press_button", "name": "Move to Trash"}"#)
    }
    #expect(throws: VoiceCommandError.refused("choose File › Delete")) {
      try steps(#"{"action": "menu", "path": ["File", "Delete"]}"#)
    }
    // The delete key on a selection is how the instruction deletes an email.
    #expect(
      try steps(#"{"action": "select", "element": 2}, {"action": "shortcut", "keys": "delete"}"#).count == 2)
  }

  @Test("a listed button asked for by name is pressed by its number; a line break typed is the return key")
  func canonicalSteps() throws {
    let listed: [ScreenContext.Element] = [
      .init(id: 2, kind: "button", label: "Reply"), .init(id: 3, kind: "link", label: "Docs"),
      .init(id: 4, kind: "link", label: "Docs"), .init(id: 5, kind: "search field", label: "Search"),
      .init(id: 6, kind: "button", label: "Save"),
    ]
    func steps(_ json: String) throws -> [VoiceCommandStep] { try self.steps(json, listed: listed) }
    #expect(try steps(#"{"action": "press_button", "name": "reply"}"#) == [.pressElement(2)])
    // A row by its name is pressed by its number too.
    #expect(
      try self.steps(
        #"{"action": "press_button", "name": "ruff.toml, Modified"}"#,
        listed: [.init(id: 9, kind: "row", label: "ruff.toml, Modified")]) == [.pressElement(9)])
    // A name a listed label starts with means that label.
    #expect(
      try self.steps(
        #"{"action": "press_button", "name": "Marketing"}"#,
        listed: [.init(id: 2, kind: "row", label: "Marketing (has unread messages)")]) == [.pressElement(2)])
    // A field of that name is no button: left for the search to find one.
    #expect(try steps(#"{"action": "press_button", "name": "Search"}"#) == [.pressButton("Search")])
    // After a step that may bring another window or sheet forward, the old
    // window's numbers no longer say what a name means.
    #expect(
      try steps(#"{"action": "press", "element": 2}, {"action": "press_button", "name": "Save"}"#)
        == [.pressElement(2), .pressButton("Save")])
    #expect(
      try steps(#"{"action": "shortcut", "keys": "cmd+n"}, {"action": "press_button", "name": "Save"}"#).last
        == .pressButton("Save"))
    #expect(
      try steps(#"{"action": "focus", "element": 5}, {"action": "press_button", "name": "Save"}"#).last
        == .pressElement(6))
    // Typing changes what a search lists: a name after it is searched for afresh.
    #expect(
      try steps(#"{"action": "type", "text": "Save"}, {"action": "press_button", "name": "Save"}"#).last
        == .pressButton("Save"))
    // Two listed under that name: left for the search to decide.
    #expect(try steps(#"{"action": "press_button", "name": "Docs"}"#) == [.pressButton("Docs")])
    #expect(try steps(#"{"action": "press_button", "name": "Send"}"#) == [.pressButton("Send")])
    let enter = KeyChord(modifiers: [], key: .code(0x24))
    #expect(
      try steps(#"{"action": "type", "text": "git status"}, {"action": "type", "text": "\n"}"#)
        == [.type("git status"), .shortcut(enter)])
    #expect(try steps(#"{"action": "type", "text": "a\nb"}"#) == [.type("a\nb")])
    // A key's name typed as a whole step is the key; in a sentence it's text.
    #expect(try steps(#"{"action": "type", "text": "Return"}"#) == [.shortcut(enter)])
    #expect(try steps(#"{"action": "type", "text": "return the book"}"#) == [.type("return the book")])
    // After a step that may change the window, still the key.
    #expect(
      try steps(#"{"action": "menu", "path": ["Edit", "Find"]}, {"action": "type", "text": "escape"}"#).last
        == .shortcut(KeyChord(modifiers: [], key: .code(0x35))))
    // Two line breaks are a blank line, which one Return isn't.
    #expect(try steps(#"{"action": "type", "text": "\n\n"}"#) == [.type("\n\n")])
  }

  @Test("a step that does the same twice never repeats; another may, up to five times running")
  func repeatedSteps() throws {
    func repeated(_ step: String, _ count: Int, listed: [ScreenContext.Element] = []) throws -> Int {
      try steps(Array(repeating: step, count: count).joined(separator: ", "), listed: listed).count
    }
    let open = #"{"action": "open_app", "app": "Safari"}"#
    #expect(throws: VoiceCommandError.repeatedStep("open_app")) { try repeated(open, 2) }
    #expect(VoiceCommandError.repeatedStep("open_app").isRetryable)
    // "Click Next twice", "tab four times".
    let next: [ScreenContext.Element] = [.init(id: 4, kind: "button", label: "Next")]
    #expect(try repeated(#"{"action": "press", "element": 4}"#, 2, listed: next) == 2)
    #expect(try repeated(#"{"action": "shortcut", "keys": "tab"}"#, 4) == 4)
    #expect(try repeated(#"{"action": "scroll", "direction": "down"}"#, 5) == 5)
    // Return ten times over a remark.
    #expect(throws: VoiceCommandError.repeatedStep("shortcut")) {
      try repeated(#"{"action": "shortcut", "keys": "return"}"#, 6)
    }
  }

  @Test("scrolling to an end and the brightness keys parse")
  func endsAndBrightness() throws {
    #expect(try steps(#"{"action": "scroll", "direction": "top"}"#) == [.scroll(.top, element: nil)])
    #expect(try steps(#"{"action": "media", "control": "brightness_down"}"#) == [.media(.brightnessDown)])
    #expect(MediaKey.brightnessUp.systemKeyType == 2 && MediaKey.brightnessDown.systemKeyType == 3)
  }

  @Test("a group of steps planned twice over is a loop; a group that differs isn't")
  func repeatedBlocks() throws {
    let loop = [
      #"{"action": "shortcut", "keys": "cmd+t"}"#, #"{"action": "type", "text": "mute"}"#,
      #"{"action": "shortcut", "keys": "return"}"#,
    ].joined(separator: ", ")
    #expect(throws: VoiceCommandError.repeatedStep("shortcut, type, shortcut")) { try steps(loop + ", " + loop) }
    let distinct =
      #"{"action": "shortcut", "keys": "cmd+t"}, {"action": "type", "text": "a"}, "#
      + #"{"action": "shortcut", "keys": "cmd+t"}, {"action": "type", "text": "b"}"#
    #expect(try steps(distinct).count == 4)
  }

  @Test("one step back three times among others is a loop; twice is a plan")
  func cyclingSteps() throws {
    let find = #"{"action": "shortcut", "keys": "cmd+f"}"#
    let esc = #"{"action": "shortcut", "keys": "escape"}"#
    let open = #"{"action": "shortcut", "keys": "cmd+o"}"#
    #expect(throws: VoiceCommandError.repeatedStep("shortcut")) {
      try steps([find, esc, open, find, open, esc, find].joined(separator: ", "))
    }
    // Find, type, escape, then find again: a second search, fine.
    let typed = #"{"action": "type", "text": "fox"}"#
    #expect(try steps([find, typed, esc, find, typed].joined(separator: ", ")).count == 5)
  }

  @Test("a cell, listed as clickable, can be selected as well as pressed")
  func selectClickable() throws {
    let cell: [ScreenContext.Element] = [.init(id: 7, kind: "clickable", label: "Report.pdf")]
    #expect(try steps(#"{"action": "select", "element": 7}"#, listed: cell) == [.select(7)])
  }

  @Test("a step's public log name is its action alone, never what it names or types")
  func logNames() {
    #expect(VoiceCommandStep.type("my password").action.rawValue == "type")
    #expect(VoiceCommandStep.openURL(URL(string: "https://example.com/a?q=secret")!).action.rawValue == "open_url")
    #expect(VoiceCommandStep.chooseMenuItem(["File", "Secret Project"]).action.rawValue == "menu")
    #expect(VoiceCommandStep.select(4).action == .select)
  }

  @Test("the planner's schema offers exactly the actions the parser reads")
  func actionsAgree() {
    let names = Set(VoiceCommandStep.Action.allCases.map(\.rawValue))
    #expect(names.count == VoiceCommandStep.Action.allCases.count)
    #expect(names.contains("press_button") && names.contains("set_value") && names.contains("window"))
  }

  private func button(_ id: Int) -> ScreenContext.Element { .init(id: id, kind: "button", label: "Send") }
  private func field(_ id: Int) -> ScreenContext.Element { .init(id: id, kind: "text field", label: "To") }

  @Test("press and focus name an element by number")
  func elementSteps() throws {
    let reply =
      #"{"steps": [{"action": "focus", "element": 2}, {"action": "type", "text": "x"}, {"action": "press", "element": 1}]}"#
    #expect(
      try VoiceCommandStep.steps(fromReply: reply, maxSteps: 10, listed: [button(1), field(2)])
        == [.focusElement(2), .type("x"), .pressElement(1)])
    // The schema makes it an integer: a string is a reply off-schema, refused.
    #expect(throws: VoiceCommandError.malformedReply) {
      try VoiceCommandStep.steps(
        fromReply: #"{"steps": [{"action": "press", "element": "12"}]}"#, maxSteps: 10, listed: [button(12)])
    }
    #expect(throws: VoiceCommandError.unknownElement(2)) {
      try VoiceCommandStep.steps(fromReply: reply, maxSteps: 10, listed: [button(1)])
    }
    #expect(throws: VoiceCommandError.malformedReply) {
      try VoiceCommandStep.steps(fromReply: #"{"steps": [{"action": "press"}]}"#, maxSteps: 10, listed: [button(1)])
    }
  }
}
