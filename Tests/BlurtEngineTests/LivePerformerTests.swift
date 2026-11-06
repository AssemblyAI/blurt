#if os(macOS)
  import AppKit
  import ApplicationServices
  import Foundation
  import Testing

  @testable import BlurtEngine

  /// The real performer (`SystemVoiceCommandPerformer`) against a real app:
  /// the fixture window (`Tests/CommandFixture`), which records what was done
  /// to it. Each step is judged by that record — a press it saw, a slider's
  /// value, the selected row — never a screenshot.
  ///
  /// Two gates, both needed: BLURT_LIVE_AX_TESTS=1, since the suite clicks,
  /// moves the pointer and drives the menu bar of the machine it runs on; and
  /// Accessibility trust for the process running it (the terminal, or Xcode).
  /// And one guard on every step: the fixture must be the app in front, or the
  /// suite stops — input meant for it must never land in another app.
  @Suite(
    "Live performer", .serialized, .tags(.drivesThisMac),
    .drivesThisMac("BLURT_LIVE_AX_TESTS", to: "run the performer against the fixture app"),
    .timeLimit(.minutes(1)))
  struct LivePerformerTests {
    @Test("every element action lands in the fixture, as the fixture records it")
    func elementActions() async throws {
      let fixture = try await Fixture.launch()
      defer { fixture.quit() }
      let performer = SystemVoiceCommandPerformer()
      await performer.commandStarting()
      let screen = await performer.screenContext()
      #expect(screen.appName == "CommandFixture")
      func id(_ kind: String, _ label: String) throws -> Int {
        try #require(screen.elements.first { $0.kind == kind && $0.label == label }?.id, "\(kind) \(label) not listed")
      }
      func run(_ step: VoiceCommandStep) async throws -> String? {
        try await fixture.requireFrontmost()
        let how = try await performer.perform(step)
        try await Task.sleep(for: performer.settle)
        return how
      }

      #expect(try await run(.pressElement(id("button", "Reply"))) == "AXPress")
      #expect(try await fixture.state(until: { $0.pressed == ["Reply"] }).pressed == ["Reply"])
      // A native app's press is trusted even when nothing it reads changes —
      // checked, a Send whose window stays put was pressed twice, and so was
      // every key of Calculator's (`SystemVoiceCommandPerformer.checksPress`).
      #expect(try await run(.pressElement(id("button", "Send"))) == "AXPress")
      #expect(try await fixture.state(until: { $0.pressed.count == 2 }).pressed == ["Reply", "Send"])

      await #expect(throws: VoiceCommandError.refused("press Delete")) {
        try await run(.pressElement(id("button", "Delete")))
      }
      #expect(try fixture.state().pressed == ["Reply", "Send"])

      let focused = try await run(.focusElement(id("text field", "Search")))
      let field = try await fixture.state(until: { $0.focused == "Search" })
      #expect(field.selection == [0, "old search text".count], "focus noted: \(focused ?? "")")

      _ = try await run(.setValue(element: id("slider", "Volume"), value: "30"))
      #expect(try await fixture.state(until: { $0.slider == 30 }).slider == 30)
      _ = try await run(.increment(id("slider", "Volume")))
      #expect(try await fixture.state(until: { $0.slider > 30 }).slider > 30)

      _ = try await run(.select(id("row", "Albums")))
      #expect(try await fixture.state(until: { $0.row == "Albums" }).row == "Albums")

      _ = try await run(.pressButton("reply"))
      #expect(try await fixture.state(until: { $0.pressed.count == 3 }).pressed.last == "Reply")

      await performer.commandEnded()
    }

    @Test("menu items, scrolling and window arrangement land in the fixture; a destructive item is refused")
    func appActions() async throws {
      let fixture = try await Fixture.launch()
      defer { fixture.quit() }
      let performer = SystemVoiceCommandPerformer()
      func run(_ step: VoiceCommandStep) async throws {
        try await fixture.requireFrontmost()
        _ = try await performer.perform(step)
      }

      try await run(.chooseMenuItem(["Fixture", "make noise"]))
      #expect(try await fixture.state(until: { $0.menu == ["Make Noise"] }).menu == ["Make Noise"])
      await #expect(throws: VoiceCommandError.refused("choose Fixture › Move to Trash")) {
        try await run(.chooseMenuItem(["Fixture", "Move to Trash"]))
      }
      #expect(try fixture.state().menu == ["Make Noise"])
      // A wrong path whose last title is right: that item, wherever it is.
      try await run(.chooseMenuItem(["Edit", "Make Noise"]))
      #expect(try await fixture.state(until: { $0.menu.count == 2 }).menu == ["Make Noise", "Make Noise"])

      _ = await performer.screenContext()
      let before = try fixture.state().scrollY
      try await run(.scroll(.down, element: nil))
      #expect(try await fixture.state(until: { $0.scrollY != before }).scrollY != before)

      try await run(.window(.leftHalf))
      let screen = try #require(NSScreen.main?.visibleFrame)
      let moved = try await fixture.state(until: { abs($0.windowX - screen.minX) < 2 })
      #expect(abs(moved.windowWidth - screen.width / 2) < 2)
    }
  }

  /// The fixture app, launched for one test and quit after it.
  private struct Fixture {
    let process: Process
    let statePath: URL

    /// What the fixture recorded (`Tests/CommandFixture/main.swift`).
    struct State: Decodable {
      var pressed: [String] = []
      var menu: [String] = []
      var focused: String?
      /// The field's selected range, `[location, length]`; empty when it isn't focused.
      var selection: [Int] = []
      var slider: Double = 0
      var row: String?
      var scrollY: Double = 0
      var windowX: Double = 0
      var windowWidth: Double = 0
    }

    /// Built beside the test bundle, as a dependency of the test target —
    /// found from a class in the bundle, since Swift Testing runs it under a
    /// helper whose main bundle is the toolchain's.
    static var executable: URL {
      Bundle(for: BundleLocator.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CommandFixture")
    }

    private final class BundleLocator {}

    static func launch() async throws -> Fixture {
      let state = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).json")
      let process = Process()
      process.executableURL = executable
      process.arguments = [state.path]
      try process.run()
      let fixture = Fixture(process: process, statePath: state)
      do {
        _ = try await fixture.state(until: { _ in true })
        // A process spawned from the test can't take the front by itself,
        // and only a registered app may hand it over: the test process
        // becomes one (an accessory: no Dock icon), then activates it.
        await MacDriver.becomeAccessory()
        _ = await MainActor.run { NSRunningApplication(processIdentifier: process.processIdentifier)?.activate() }
        for _ in 0..<50 where await fixture.isFrontmost() == false {
          try await Task.sleep(for: .milliseconds(100))
        }
        try await fixture.requireFrontmost()
      } catch {
        fixture.quit()
        throw error
      }
      return fixture
    }

    func isFrontmost() async -> Bool {
      await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier } == process.processIdentifier
    }

    /// Stops the test unless the fixture is in front: the guard every step passes.
    func requireFrontmost() async throws {
      let front = await isFrontmost()
      try #require(front, "the fixture isn't the app in front; stopping before input goes anywhere else")
    }

    func state() throws -> State {
      try JSONDecoder().decode(State.self, from: Data(contentsOf: statePath))
    }

    /// The fixture's state once `condition` holds, or its last state after two seconds.
    func state(until condition: (State) -> Bool) async throws -> State {
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while ContinuousClock.now < deadline {
        if let state = try? state(), condition(state) { return state }
        try await Task.sleep(for: .milliseconds(25))
      }
      return try state()
    }

    func quit() {
      process.terminate()
      try? FileManager.default.removeItem(at: statePath)
    }
  }
#endif
