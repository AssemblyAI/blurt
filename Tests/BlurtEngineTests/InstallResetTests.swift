import Testing

@testable import BlurtEngine

@Suite("InstallReset")
struct InstallResetTests {
  @Test("runs every step, and a clean sweep has nothing to say")
  func runsEveryStep() {
    let spy = ResetSpy()

    let alert = spy.makeReset().run()

    #expect(spy.clearedSettings)
    #expect(spy.clearedAPIKey)
    #expect(spy.resetPermissions)
    #expect(spy.clearedLogs)
    // nil is the shell's cue that the install is clean — it quits on it.
    #expect(alert == nil)
  }

  /// The property the whole type exists for: a half-reset install is the state
  /// this gets the user *out* of, so a failed step must not skip the ones after
  /// it. Failing the first two proves the tail still ran.
  @Test("a failed step doesn't skip the ones after it")
  func doesNotShortCircuit() {
    let spy = ResetSpy(apiKey: false, permissions: false)

    let alert = spy.makeReset().run()

    #expect(spy.resetPermissions)
    #expect(spy.clearedLogs)
    #expect(alert != nil)
  }

  @Test("the alert reports the step that actually failed")
  func reportsTheFailedStep() throws {
    let alert = try #require(ResetSpy(apiKey: true, permissions: false, logs: true).makeReset().run())

    // Each step's answer lands in its own field of the report behind this — a
    // swapped pair would name the wrong thing here.
    #expect(alert.message.contains("permissions"))
    #expect(!alert.message.contains("API key"))
  }
}
