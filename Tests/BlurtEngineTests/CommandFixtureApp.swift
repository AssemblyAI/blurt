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
        _ = try await fixture.state { _ in true }
        // A process spawned from the test can't take the front by itself,
        // and only a registered app may hand it over: the test process
        // becomes one (an accessory: no Dock icon), then activates it.
        await MacDriver.becomeAccessory()
        _ = await MainActor.run { NSRunningApplication(processIdentifier: child.processIdentifier)?.activate() }
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
        if let state = try? state(), condition(state) {
          return state
        }
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
