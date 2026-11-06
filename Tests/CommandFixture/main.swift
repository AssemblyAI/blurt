// A window with one of each control Control Your Mac acts on, for the live
// performer suite (`LivePerformerTests`): it writes what was done to it — a
// press, a focus and its selection, a slider's value, a selected row, a menu
// item chosen, a scroll — as JSON to the path it's given, after every change,
// so the suite judges each step by the app's own record, never a screenshot.
// It never runs in a normal `swift test`: the suite that launches it is gated
// on BLURT_LIVE_AX_TESTS=1 and Accessibility trust.

#if os(macOS)
  import AppKit

  @MainActor
  final class Fixture: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate
  {
    private let statePath: String
    private var state: [String: Any] = ["pressed": [String](), "menu": [String]()]
    private let window = NSWindow(
      contentRect: NSRect(x: 200, y: 200, width: 520, height: 420), styleMask: [.titled, .resizable],
      backing: .buffered, defer: false)
    private let field = NSTextField(string: "old search text")
    private let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let table = NSTableView()
    private let rows = ["Songs", "Albums", "Artists"]
    private let scroll = NSScrollView()

    init(statePath: String) {
      self.statePath = statePath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
      window.title = "Blurt Command Fixture"
      let reply = NSButton(title: "Reply", target: self, action: #selector(pressed(_:)))
      let delete = NSButton(title: "Delete", target: self, action: #selector(pressed(_:)))
      // Changes nothing Blurt can see, as a Send whose window stays put: in a
      // native app its press is trusted, so it's pressed once.
      let send = NSButton(title: "Send", target: self, action: #selector(pressed(_:)))
      field.placeholderString = "Search"
      field.delegate = self
      slider.setAccessibilityLabel("Volume")
      slider.target = self
      slider.action = #selector(slid)
      slider.numberOfTickMarks = 0

      let column = NSTableColumn(identifier: .init("name"))
      table.addTableColumn(column)
      table.headerView = nil
      table.dataSource = self
      table.delegate = self
      let list = NSScrollView()
      list.documentView = table
      list.hasVerticalScroller = true

      let tall = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 2_000))
      scroll.documentView = tall
      scroll.hasVerticalScroller = true
      scroll.setAccessibilityLabel("Notes")
      scroll.contentView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
      tall.scroll(NSPoint(x: 0, y: 2_000))

      let stack = NSStackView(views: [reply, delete, send, field, slider, list, scroll])
      stack.orientation = .vertical
      stack.alignment = .leading
      stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
      for view in [field, slider, list, scroll] { view.widthAnchor.constraint(equalToConstant: 300).isActive = true }
      list.heightAnchor.constraint(equalToConstant: 80).isActive = true
      scroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
      window.contentView = stack

      installMenu()

      NotificationCenter.default.addObserver(
        self, selector: #selector(scrolled), name: NSTextView.didChangeSelectionNotification, object: nil)
      for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: name, object: window)
      }
      window.makeKeyAndOrderFront(nil)
      window.makeFirstResponder(nil)
      NSApp.activate()
      record()
    }

    /// A Fixture menu: one item to choose, one the destructive guard refuses.
    private func installMenu() {
      let menu = NSMenu(title: "Fixture")
      menu.addItem(withTitle: "Make Noise", action: #selector(chose(_:)), keyEquivalent: "")
      menu.addItem(withTitle: "Move to Trash", action: #selector(chose(_:)), keyEquivalent: "")
      let main = NSMenu()
      main.addItem(NSMenuItem(title: "CommandFixture", action: nil, keyEquivalent: ""))
      let item = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")
      item.submenu = menu
      main.addItem(item)
      NSApp.mainMenu = main
    }

    /// Reply visibly answers — the window's title changes, as a press that
    /// opens something does — so one press is the whole step.
    @objc private func pressed(_ sender: NSButton) {
      let pressed = (state["pressed"] as? [String] ?? []) + [sender.title]
      state["pressed"] = pressed
      if sender.title == "Reply" { window.title = "Replied \(pressed.count { $0 == "Reply" })" }
      record()
    }

    @objc private func chose(_ sender: NSMenuItem) {
      state["menu"] = (state["menu"] as? [String] ?? []) + [sender.title]
      record()
    }

    @objc private func slid() { record() }
    /// A scroll, a move, a resize or a selection: anything the state reads off the views.
    @objc private func scrolled() { record() }

    func controlTextDidBeginEditing(_ obj: Notification) { record() }
    func controlTextDidChange(_ obj: Notification) { record() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      NSTextField(labelWithString: rows[row])
    }

    func tableViewSelectionDidChange(_ notification: Notification) { record() }

    /// The whole state, written after every change; the field's selection is
    /// read from its editor, which exists only while it's focused.
    private func record() {
      let editor = window.firstResponder as? NSTextView
      let focused = editor != nil && editor?.delegate === field
      state["focused"] = focused ? "Search" : nil
      state["selection"] = focused ? editor.map { [$0.selectedRange().location, $0.selectedRange().length] } ?? [] : []
      state["text"] = field.stringValue
      state["slider"] = slider.doubleValue
      state["row"] = table.selectedRow >= 0 ? rows[table.selectedRow] : nil
      state["scrollY"] = scroll.contentView.bounds.origin.y
      state["windowX"] = window.frame.origin.x
      state["windowWidth"] = window.frame.width
      guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
      try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }
  }

  let path = CommandLine.arguments.dropFirst().first ?? "/tmp/blurt-command-fixture.json"
  let app = NSApplication.shared
  app.setActivationPolicy(.regular)
  let fixture = MainActor.assumeIsolated { Fixture(statePath: path) }
  app.delegate = fixture
  app.run()
#endif
