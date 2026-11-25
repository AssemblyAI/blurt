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
  /// BLURT_RECORD_TREE_ONLY picks some ("Slack,Mail"); all of them by default.
  @Suite(
    "Screen tree recorder", .serialized, .tags(.drivesThisMac),
    .drivesThisMac("BLURT_RECORD_TREE", to: "record the screen trees"))
  struct ScreenTreeRecorder {
    @Test("every listed app's largest window, recorded with fake text")
    func record() async throws {
      await MacDriver.becomeAccessory()
      let wanted = MacDriver.picks("BLURT_RECORD_TREE_ONLY")
      let performer = SystemVoiceCommandPerformer()
      for recording in RecordedNode.recordings where wanted(recording.name) {
        let name = recording.name
        try await MacDriver.bringToFront(recording.app, with: performer)
        if let start = recording.start { await MacDriver.press(labelled: start, with: performer) }
        try await Task.sleep(for: .seconds(2))
        let pid = try #require(await KeyInjector.frontmostApp()?.processIdentifier)
        // Its largest window: Mail's front one can be a blank new message.
        let app = AXRead.app(pid)
        let windows = (AXRead.value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).map(AXRead.capped)
        let largest = windows.max { area($0) < area($1) }
        let window = try #require(largest ?? AXRead.window(of: app), "\(name) has no window")
        var recorder = FakeTextRecorder()
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

#endif
