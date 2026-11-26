#if os(macOS)
  import AppKit
  import ApplicationServices
  import Foundation
  import Testing

  @testable import BlurtEngine

  /// The fixture app, launched for one test and quit after it.
  struct CommandFixtureApp {
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

    private final class BundleLocator {}

    /// Built beside the test bundle, as a dependency of the test target —
    /// found from a class in the bundle, since Swift Testing runs it under a
    /// helper whose main bundle is the toolchain's.
    static var executable: URL {
      Bundle(for: BundleLocator.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CommandFixture")
    }

    let process: Process
    let statePath: URL

    static func launch() async throws -> Self {
      let state = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).json")
      let child = Process()
      child.executableURL = executable
      child.arguments = [state.path]
      try child.run()
      let fixture = Self(process: child, statePath: state)
      do {
        // A first launch of a freshly built binary can take seconds (the
        // system checks it before it runs); `state(until:)`'s bound covers it.
        _ = try await fixture.state { _ in true }
        // A process spawned from the test can't take the front by itself,
        // and only a registered app may hand it over: the test process
        // becomes one (an accessory: no Dock icon), then activates it.
        await MacDriver.becomeAccessory()
        _ = await MainActor.run { NSRunningApplication(processIdentifier: child.processIdentifier)?.activate() }
        for _ in 0..<50 where await fixture.isFrontmost() == false {
          // wall-clock-ok: drives real hardware or a real app, which run on real time
          try await Task.sleep(for: .milliseconds(100))
        }
        try await fixture.requireFrontmost()
        // The menu bar fills in a moment after the app is in front, and the
        // performer finds menu items there: "Fixture › Make Noise" was not
        // found on a CI run whose launch was otherwise fine.
        for _ in 0..<50 where fixture.hasFixtureMenu() == false {
          // wall-clock-ok: a real app's menu bar, which fills in on real time
          try await Task.sleep(for: .milliseconds(100))
        }
        try #require(fixture.hasFixtureMenu(), "the fixture's menu bar never listed its Fixture menu")
      } catch {
        fixture.quit()
        throw error
      }
      return fixture
    }

    func isFrontmost() async -> Bool {
      await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier } == process.processIdentifier
    }

    /// Whether Accessibility reads the Fixture menu in the fixture's menu bar.
    func hasFixtureMenu() -> Bool {
      guard let bar = AXRead.element(AXRead.app(process.processIdentifier), kAXMenuBarAttribute),
        let menus = AXRead.value(bar, kAXChildrenAttribute) as? [AXUIElement]
      else {
        return false
      }
      return menus.contains { AXRead.string($0, kAXTitleAttribute) == "Fixture" }
    }

    /// Stops the test unless the fixture is in front: the guard every step passes.
    func requireFrontmost() async throws {
      let front = await isFrontmost()
      try #require(front, "the fixture isn't the app in front; stopping before input goes anywhere else")
    }

    func state() throws -> State {
      try JSONDecoder().decode(State.self, from: Data(contentsOf: statePath))
    }

    /// The fixture's state once `condition` holds, or its last state after
    /// `waitUntil`'s 30 s. Every caller expects the condition to hold, so the
    /// bound only catches a hang, and a timeout isn't rethrown: the caller's
    /// expectation on the state returned names what never happened.
    func state(until condition: (State) -> Bool) async throws -> State {
      do {
        try await waitUntil("the fixture's state to match") { (try? state()).map(condition) ?? false }
      } catch is WaitTimedOut {
        // Fall through to the last state, for the caller's expectation to report.
      }
      return try state()
    }

    func quit() {
      process.terminate()
      try? FileManager.default.removeItem(at: statePath)
    }
  }
#endif
