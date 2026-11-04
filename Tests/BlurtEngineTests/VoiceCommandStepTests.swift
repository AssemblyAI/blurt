import Foundation
import Testing

@testable import BlurtEngine

@Suite("VoiceCommandStep")
struct VoiceCommandStepTests {
  private func steps(_ reply: String, maxSteps: Int = 10) throws -> [VoiceCommandStep] {
    try VoiceCommandStep.steps(fromReply: reply, maxSteps: maxSteps)
  }

  @Test("every action in the instruction reads as its step, in order")
  func parsesEveryAction() throws {
    let reply = """
      {"steps": [
        {"action": "open_app", "app": "Slack"},
        {"action": "shortcut", "keys": "cmd+k"},
        {"action": "type", "text": "budget"},
        {"action": "hide_app", "app": "Mail"},
        {"action": "quit_app", "app": "Music"},
        {"action": "open_url", "url": "https://www.google.com/search?q=weather"},
        {"action": "media", "control": "volume_up"}
      ]}
      """
    #expect(
      try steps(reply) == [
        .openApp("Slack"),
        .shortcut(KeyChord(modifiers: .command, key: .character("k"))),
        .type("budget"),
        .hideApp("Mail"),
        .quitApp("Music"),
        .openURL(try #require(URL(string: "https://www.google.com/search?q=weather"))),
        .media(.volumeUp),
      ])
  }

  @Test("a reply off the schema — fenced, or with prose — is refused, not dug out")
  func refusesWrapping() throws {
    let reply = "Sure:\n```json\n{\"steps\": [{\"action\": \"open_app\", \"app\": \"Notes\"}]}\n```"
    #expect(throws: VoiceCommandError.malformedReply) { try steps(reply) }
  }

  @Test("no steps is a command Blurt can't do; no JSON is an unreadable plan")
  func emptyAndMalformed() {
    #expect(throws: VoiceCommandError.notUnderstood) { try steps(#"{"steps": []}"#) }
    #expect(throws: VoiceCommandError.malformedReply) { try steps("I can't help with that.") }
    #expect(throws: VoiceCommandError.malformedReply) { try steps(#"{"steps": [{"action": "open_app"}]}"#) }
  }

  @Test("one bad step refuses the whole plan: half a plan is a different command")
  func oneBadStepRefusesAll() {
    let reply = #"{"steps": [{"action": "open_app", "app": "Terminal"}, {"action": "run_script", "text": "rm"}]}"#
    #expect(throws: VoiceCommandError.unsupportedAction("run_script")) { try steps(reply) }
  }

  @Test("only web and mail links open: a file or an app's own scheme is refused")
  func refusesOtherSchemes() {
    for url in ["file:///etc/passwd", "x-apple.systempreferences:com.apple.preference.security", "slack://open"] {
      #expect(throws: VoiceCommandError.unsafeURL(url)) {
        try steps(#"{"steps": [{"action": "open_url", "url": "\#(url)"}]}"#)
      }
    }
    #expect(throws: Never.self) {
      try steps(#"{"steps": [{"action": "open_url", "url": "mailto:team@example.com"}]}"#)
    }
  }

  @Test("an unknown shortcut, media key, or too many steps is refused")
  func refusesTheRest() {
    #expect(throws: VoiceCommandError.unknownShortcut("cmd+hyper")) {
      try steps(#"{"steps": [{"action": "shortcut", "keys": "cmd+hyper"}]}"#)
    }
    #expect(throws: VoiceCommandError.unsupportedAction("media eject")) {
      try steps(#"{"steps": [{"action": "media", "control": "eject"}]}"#)
    }
    let three =
      #"{"steps": [{"action": "media", "control": "mute"}, "#
      + #"{"action": "media", "control": "mute"}, {"action": "media", "control": "mute"}]}"#
    #expect(throws: VoiceCommandError.tooManySteps) { try steps(three, maxSteps: 2) }
  }

  @Test("typed text keeps its spaces, and a long one is refused rather than cut")
  func typedText() throws {
    #expect(try steps(#"{"steps": [{"action": "type", "text": " hi\n"}]}"#) == [.type(" hi\n")])
    let long = String(repeating: "a", count: VoiceCommandStep.maxTypedCharacters + 1)
    #expect(throws: VoiceCommandError.malformedReply) {
      try steps(#"{"steps": [{"action": "type", "text": "\#(long)"}]}"#)
    }
  }

  @Test("a slider's number reads back the same on every locale: 0.5, never the 0,5 a German Mac would write")
  func plainNumbers() throws {
    let steps = try VoiceCommandStep.steps(
      fromReply: #"{"steps": [{"action": "set_value", "element": 1, "value": 0.5}, "#
        + #"{"action": "set_value", "element": 1, "value": 40}]}"#, maxSteps: 10,
      listed: [.init(id: 1, kind: "slider", label: "Volume")])
    #expect(steps == [.setValue(element: 1, value: "0.5"), .setValue(element: 1, value: "40")])
    #expect(Double("0.5") == 0.5)
  }

  @Test("a chord is any modifiers and exactly one key, by any of their names")
  func chords() {
    #expect(KeyChord("cmd+shift+t") == KeyChord(modifiers: [.command, .shift], key: .character("t")))
    #expect(KeyChord("Control + Tab") == KeyChord(modifiers: .control, key: .code(0x30)))
    #expect(KeyChord("option+left") == KeyChord(modifiers: .option, key: .code(0x7B)))
    #expect(KeyChord("escape") == KeyChord(modifiers: [], key: .code(0x35)))
    #expect(KeyChord("f12") == KeyChord(modifiers: [], key: .code(0x6F)))
    #expect(KeyChord("cmd") == nil)
    #expect(KeyChord("cmd+a+b") == nil)
    #expect(KeyChord("cmd+hyper") == nil)
  }

  @Test("an app is matched by name, else by its start, else by a whole word, ignoring case and accents")
  func appNames() {
    let apps = ["Google Chrome", "Visual Studio Code", "Notes", "Notion", "Café", "Safari"]
    #expect(NameMatch.best(for: "notes", among: apps) == "Notes")
    #expect(NameMatch.best(for: "Visual Studio", among: apps) == "Visual Studio Code")
    #expect(NameMatch.best(for: "chrome", among: apps) == "Google Chrome")
    #expect(NameMatch.best(for: "cafe.app", among: apps) == "Café")
    #expect(NameMatch.best(for: "Not", among: apps) == "Notes")
    #expect(NameMatch.best(for: "Firefox", among: apps) == nil)
    #expect(NameMatch.best(for: "", among: apps) == nil)
  }

  @Test("an app the user can act on is named on the pill")
  func pillNotices() {
    #expect(
      VoiceCommandError.appNotFound("Figma").pillNotice == PillNotice(subject: "Figma", predicate: "isn’t installed"))
    #expect(VoiceCommandError.appNotRunning("Mail").pillNotice?.text == "Mail isn’t open")
    #expect(VoiceCommandError.malformedReply.pillNotice == nil)
  }

  @Test("a character key is the character, found on the user's layout; a named key is its fixed code")
  func layoutAwareKeys() throws {
    let k = try #require(KeyChord("cmd+k"))
    #expect(k.key == .character("k"))
    // Where it is on a US layout: the fallback when the user's can't be read.
    #expect(k.ansiKeyCode == 0x28)
    #expect(try #require(KeyChord("cmd+K")).key == .character("k"))
    #expect(try #require(KeyChord("return")).key == .code(0x24))
    #expect(try #require(KeyChord("cmd+,")).ansiKeyCode == 0x2B)
  }

  @Test("a button is named, a menu item is a path from the menu's title of two to four items")
  func accessibilitySteps() throws {
    #expect(try steps(#"{"steps": [{"action": "press_button", "name": "Send"}]}"#) == [.pressButton("Send")])
    #expect(
      try steps(#"{"steps": [{"action": "menu", "path": ["File", "New Window"]}]}"#)
        == [.chooseMenuItem(["File", "New Window"])])
    #expect(throws: VoiceCommandError.malformedReply) {
      try steps(#"{"steps": [{"action": "menu", "path": ["File"]}]}"#)
    }
    #expect(throws: VoiceCommandError.malformedReply) {
      try steps(#"{"steps": [{"action": "menu", "path": ["A", "B", "C", "D", "E"]}]}"#)
    }
    #expect(throws: VoiceCommandError.malformedReply) {
      try steps(#"{"steps": [{"action": "press_button"}]}"#)
    }
  }

  @Test("⌘ with delete is refused whatever the plan says; delete alone, and other ⌘ chords, are not")
  func destructiveChords() {
    for keys in [
      "cmd+delete", "cmd+shift+delete", "cmd+option+shift+backspace", "cmd+forward_delete", "cmd+shift+q",
      "cmd+option+shift+q",
    ] {
      #expect(throws: VoiceCommandError.refused("press \(keys)")) {
        try steps(#"{"steps": [{"action": "shortcut", "keys": "\#(keys)"}]}"#)
      }
    }
    #expect(throws: Never.self) { try steps(#"{"steps": [{"action": "shortcut", "keys": "delete"}]}"#) }
    #expect(throws: Never.self) { try steps(#"{"steps": [{"action": "shortcut", "keys": "cmd+d"}]}"#) }
    // Quitting an app, and locking the screen, are fine.
    #expect(throws: Never.self) { try steps(#"{"steps": [{"action": "shortcut", "keys": "cmd+q"}]}"#) }
    #expect(throws: Never.self) { try steps(#"{"steps": [{"action": "shortcut", "keys": "ctrl+cmd+q"}]}"#) }
  }

  @Test("a button or menu item that deletes, erases or powers off is refused, by whole words")
  func destructiveLabels() {
    for label in ["Move to Trash", "Empty Trash…", "Delete", "Erase Disk", "Shut Down…", "Restart", "Log Out Alex…"] {
      #expect(DestructiveGuard.isDestructive(label: label), "\(label)")
    }
    for label in ["Send", "Show Log", "Format", "Restarted Jobs", "Deleted Items Folder"] {
      #expect(!DestructiveGuard.isDestructive(label: label), "\(label)")
    }
  }

  @Test("the element search finds the pressable one by label, nearest the top first, within its limit")
  func elementSearch() {
    struct Node {
      let label: String
      let pressable: Bool
      var children: [Node] = []
    }
    let tree = Node(
      label: "window", pressable: false,
      children: [
        Node(label: "Send", pressable: false),
        Node(
          label: "toolbar", pressable: false,
          children: [Node(label: "Send Later", pressable: true), Node(label: "Send", pressable: true)]),
        Node(label: "body", pressable: false, children: [Node(label: "Send", pressable: true, children: [])]),
      ])
    func find(_ name: String, limit: Int = ElementSearch.maxElements) -> Node? {
      ElementSearch.best(
        named: name, from: tree, children: \.children, labels: { [$0.label] }, pressable: \.pressable, limit: limit)
    }
    #expect(find("send")?.label == "Send")
    #expect(find("send later")?.label == "Send Later")
    #expect(find("Archive") == nil)
    // Three nodes in, it hasn't reached the toolbar's buttons.
    #expect(find("send", limit: 3) == nil)
  }

  @Test("an app is in front when its window is the top normal one, panels and the menu bar aside")
  func windowOrder() {
    let menuBar = WindowOrder.Window(owner: 1, layer: 24)
    let pill = WindowOrder.Window(owner: 9, layer: 3)
    #expect(WindowOrder.isFrontmost(5, in: [menuBar, pill, .init(owner: 5, layer: 0), .init(owner: 6, layer: 0)]))
    #expect(!WindowOrder.isFrontmost(5, in: [menuBar, .init(owner: 6, layer: 0), .init(owner: 5, layer: 0)]))
    // No window of its own on screen: nothing to wait for.
    #expect(WindowOrder.isFrontmost(5, in: [menuBar, .init(owner: 6, layer: 0)]))
  }

  @Test("a menu item's ellipsis doesn't stop it matching")
  func menuEllipsis() {
    #expect(NameMatch.best(for: "Export", among: ["Export…", "Export as PDF…"]) == "Export…")
    #expect(NameMatch.best(for: "page setup", among: ["Page Setup..."]) == "Page Setup...")
  }

  #if os(macOS)
    @MainActor
    @Test("the machine's own layout types every letter, each from its own key")
    func currentLayout() {
      let layout = KeyboardLayout.current()
      let letters = "abcdefghijklmnopqrstuvwxyz".map { layout[$0] }
      #expect(!letters.contains(nil))
      #expect(Set(letters.compactMap { $0 }).count == 26)
    }

    @Test("a shortcut's events carry its key and every modifier, on the key-up too")
    func shortcutEvents() throws {
      let chord = try #require(KeyChord("cmd+shift+t"))
      let (down, up) = try #require(SystemVoiceCommandPerformer.events(for: chord, keyCode: 0x11))
      for event in [down, up] {
        #expect(event.getIntegerValueField(.keyboardEventKeycode) == 0x11)
        #expect(event.flags.contains(.maskCommand))
        #expect(event.flags.contains(.maskShift))
        #expect(!event.flags.contains(.maskAlternate))
      }
    }
  #endif
}
