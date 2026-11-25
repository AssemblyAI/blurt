#if os(macOS)
  import Foundation
  import Testing

  @testable import BlurtEngine

  /// `SystemVoiceCommandPerformer`'s wait for an opened app to come forward, on a
  /// `TestClock`, through the router's `execute` as a command runs it: an app
  /// that never comes forward fails the command, and a cancel during the wait
  /// abandons it — never logged as that failure.
  @MainActor
  @Suite("SystemVoiceCommandPerformer · coming forward", .timeLimit(.minutes(1)))
  struct SystemVoiceCommandPerformerFrontTests {
    /// Carries every step out as `open`'s wait for an app that never comes forward,
    /// on `clock`: the production wait without a live app to launch.
    private struct NeverForwardPerformer: VoiceCommandPerforming {
      let clock: TestClock

      func screenContext() -> ScreenContext { ScreenContext(appName: nil) }

      func perform(_: VoiceCommandStep) async throws -> String? {
        _ = try await SystemVoiceCommandPerformer.waitForFront(
          "Slack", clock: clock, look: { false }, frontmost: { false }
        )
        return nil
      }
    }

    private static let interval: Duration = .milliseconds(100)
    private static let looks = Int(SystemVoiceCommandPerformer.launchBudget / interval)

    /// Starts "open slack" with `NeverForwardPerformer` on `clock`, returned once
    /// its wait has parked on the clock for the first time.
    private func startOpenSlack(on clock: TestClock) async -> Task<DictationLog.CommandRecord, Never> {
      let fixture = makeSession(mode: .transcript("x"))
      let command = Task {
        await SelectionSpeechRouter.execute(
          "open slack",
          screen: nil,
          planner: StubPlanner(steps: [.openApp("Slack")]),
          performer: NeverForwardPerformer(clock: clock),
          session: fixture.session
        )
      }
      await clock.waitUntilSleeping(for: Self.interval)
      return command
    }

    @Test("an app that never comes forward fails the command")
    func neverForwardFails() async {
      let clock = TestClock()
      let command = await startOpenSlack(on: clock)
      clock.advance(by: Self.interval)
      for _ in 1..<Self.looks {
        await clock.waitUntilSleeping(for: Self.interval)
        clock.advance(by: Self.interval)
      }
      let record = await command.value
      #expect(record.failure?.kind == "VoiceCommandError.couldNotPerform")
      guard case .error = record.outcome else {
        Issue.record("expected a failure, got \(String(describing: record.outcome))")
        return
      }
      #expect(record.ran.count == 1)
      #expect(
        record.ran.first?.error == VoiceCommandError.couldNotPerform("bring Slack to the front").localizedDescription
      )
    }

    @Test("a cancel while the app comes forward abandons the command, not fails it")
    func cancelAbandons() async {
      let clock = TestClock()
      let command = await startOpenSlack(on: clock)
      command.cancel()
      let record = await command.value
      // Abandoned (no outcome, no failure for the error log), and the step
      // carries no error: before the wait threw on a cancel it read as "never
      // came forward", and the command was logged as failing to bring Slack to
      // the front.
      #expect(record.outcome == nil)
      #expect(record.failure == nil)
      #expect(record.ran.isEmpty)
    }

    @Test("an app that is frontmost when the wait runs out is in front enough")
    func frontmostIsEnough() async throws {
      let clock = TestClock()
      let wait = Task {
        try await SystemVoiceCommandPerformer.waitForFront(
          "Slack", clock: clock, look: { false }, frontmost: { true }
        )
      }
      for _ in 0..<Self.looks {
        await clock.waitUntilSleeping(for: Self.interval)
        clock.advance(by: Self.interval)
      }
      #expect(try await wait.value == false)
    }
  }
#endif
