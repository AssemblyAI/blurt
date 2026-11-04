#if os(macOS)
  import AppKit
  import ApplicationServices
  import Testing

  @testable import BlurtEngine

  /// Records the apps `RecordedScreenTests` replays: each brought to the
  /// front, its tree switched on as a command would (`screenContext`), then
  /// its focused window written to `Tests/ScreenTrees/<name>.json` with every
  /// string swapped for fake text. Only on request (BLURT_RECORD_TREE=1),
  /// and only on a Mac with Accessibility trust: it drives this Mac's apps.
  /// BLURT_RECORD_APPS picks some ("Slack,Mail"); all of them by default.
  @Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BLURT_RECORD_TREE"] == "1", "set BLURT_RECORD_TREE=1 to record"),
    .enabled(if: AXIsProcessTrusted(), "the process running the tests needs Accessibility trust"))
  struct ScreenTreeRecorder {
    /// Each recording, by file name; the app to open for it; and what to
    /// press first, so it's recorded in the view its tests expect (Slack's
    /// Home, not Activity).
    struct Recording {
      let name: String
      let app: String
      var start: String?
    }

    static let apps: [Recording] =
      [
        Recording(name: "1Password", app: "1Password"), Recording(name: "Code", app: "Visual Studio Code"),
        Recording(name: "Finder", app: "Finder"), Recording(name: "Mail", app: "Mail"),
        Recording(name: "Slack", app: "Slack", start: "Home"), Recording(name: "Chrome", app: "Google Chrome"),
        Recording(name: "Safari", app: "Safari"), Recording(name: "Obsidian", app: "Obsidian"),
      ]

    @Test func record() async throws {
      await MainActor.run { _ = NSApplication.shared.setActivationPolicy(.accessory) }
      let wanted = ProcessInfo.processInfo.environment["BLURT_RECORD_APPS"].map {
        Set($0.split(separator: ",").map(String.init))
      }
      let performer = SystemVoiceCommandPerformer()
      for recording in Self.apps where wanted?.contains(recording.name) ?? true {
        let name = recording.name
        _ = try await performer.perform(.openApp(recording.app))
        try await Task.sleep(for: .seconds(1))
        await performer.commandStarting()
        let screen = await performer.screenContext()
        if let start = recording.start, let element = screen.elements.first(where: { $0.label.hasPrefix(start) }) {
          _ = try? await performer.perform(.pressElement(element.id))
        }
        try await Task.sleep(for: .seconds(2))
        let pid = try #require(await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier })
        // Its largest window: Mail's front one can be a blank new message.
        let app = AXRead.app(pid)
        let windows = (AXRead.value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).map(AXRead.capped)
        let largest = windows.max { area($0) < area($1) }
        let window = try #require(largest ?? AXRead.window(of: app), "\(name) has no window")
        var recorder = Recorder()
        let tree = recorder.record(AXRead.Node(window), depth: 0)
        await performer.commandEnded()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(tree).write(to: RecordedNode.directory.appendingPathComponent("\(name).json"))
        print("recorded \(name): \(recorder.count) nodes")
      }
    }
  }

  private func area(_ window: AXUIElement) -> CGFloat {
    AXRead.frame(window).map { $0.width * $0.height } ?? 0
  }

  /// A live tree copied into `RecordedNode`s: bounded, and with every string
  /// swapped for fake text — the same fake for the same string, so labels
  /// that matched still match — apart from `keep`'s generic interface words.
  private struct Recorder {
    private(set) var count = 0
    private var fakes: [String: String] = [:]
    static let nodeLimit = 6_000

    /// Interface words that name no person, channel, file or message.
    static let keep: Set<String> = [
      "Search", "Send", "Reply", "Close", "Back", "Forward", "Home", "Activity", "Settings", "Favorites",
      "Inbox", "Sent", "Drafts", "Junk", "Archive", "Trash", "Downloads", "Documents", "Desktop", "Recents",
      "Applications", "Explorer", "Source Control", "Run and Debug", "Extensions", "New", "Share", "Edit",
      "File", "View", "Help", "Window", "Go", "Format", "Insert", "Tools", "Unreads", "Threads", "Later",
      "DMs", "Direct messages", "Channels", "All Items", "Watchtower", "Profile", "Developer", "sidebar",
    ]

    mutating func fake(_ text: String?) -> String? {
      guard let text, !text.isEmpty else { return nil }
      if Self.keep.contains(text) { return text }
      if let known = fakes[text] { return known }
      let made = "Lorem \(fakes.count + 1)"
      fakes[text] = made
      return made
    }

    mutating func record(_ node: AXRead.Node, depth: Int) -> RecordedNode {
      count += 1
      let role = node.role
      // A value only where it's a name or a row's text — never a field's contents.
      let valueNamed = role.map { ScreenSnapshot.valueNamedRoles.contains($0) || $0 == "AXStaticText" } ?? false
      let children: [RecordedNode] =
        depth < 40 && count < Self.nodeLimit ? node.children.map { record($0, depth: depth + 1) } : []
      let label = node.titleElement.map { titled in
        RecordedNode(
          role: titled.role, subrole: nil, title: fake(titled.title), nodeDescription: fake(titled.nodeDescription),
          placeholder: nil, frame: nil, pressable: false, rawValue: nil, children: [], label: nil)
      }
      return RecordedNode(
        role: role, subrole: node.subrole, title: fake(node.title), nodeDescription: fake(node.nodeDescription),
        placeholder: fake(node.placeholder), frame: node.frame, pressable: node.isPressable,
        rawValue: valueNamed ? fake(node.rawValue) : nil, children: children, label: label)
    }
  }
#endif
