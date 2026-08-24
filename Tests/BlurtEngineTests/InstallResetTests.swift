import Testing

@testable import BlurtEngine

/// Records which steps a reset actually ran, and answers each one however the
/// test asks. `InstallReset` is a sweep whose every real effect is irreversible
/// and machine-wide (defaults, the Keychain item, TCC rows, the log files), so
/// the composition is what's covered here — against doubles, never the real
/// ones.
private final class ResetSpy {
  private(set) var clearedSettings = false
  private(set) var clearedAPIKey = false
  private(set) var resetPermissions = false
  private(set) var clearedLogs = false

  let apiKeyResult: Bool
  let permissionsResult: Bool
  let logsResult: Bool

  init(apiKey: Bool = true, permissions: Bool = true, logs: Bool = true) {
    self.apiKeyResult = apiKey
    self.permissionsResult = permissions
    self.logsResult = logs
  }

  func makeReset() -> InstallReset {
    InstallReset(
      clearSettings: { self.clearedSettings = true },
      clearAPIKey: {
        self.clearedAPIKey = true
        return self.apiKeyResult
      },
      resetPermissions: {
        self.resetPermissions = true
        return self.permissionsResult
      },
      clearLogs: {
        self.clearedLogs = true
        return self.logsResult
      })
  }
}

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

/// What a partial reset *says*. The shell has no test target, so the wording is
/// the engine's — and the thing worth pinning is that every step that failed is
/// named, since the user's only next move is knowing what survived.
@Suite("InstallReset.Report.failureAlert")
struct InstallResetAlertTests {
  @Test("a complete reset has nothing to report")
  func completeSaysNothing() {
    let report = InstallReset.Report(
      apiKeyCleared: true, permissionsCleared: true, logsCleared: true)
    #expect(report.failureAlert == nil)
  }

  @Test("names the step that failed")
  func namesTheFailedStep() throws {
    let report = InstallReset.Report(
      apiKeyCleared: true, permissionsCleared: false, logsCleared: true)

    let alert = try #require(report.failureAlert)

    #expect(alert.message.contains("permissions"))
    #expect(!alert.message.contains("API key"))
    #expect(!alert.message.contains("dictation logs"))
    #expect(!alert.title.isEmpty)
  }

  @Test("names every step that failed")
  func namesEveryFailedStep() throws {
    let report = InstallReset.Report(
      apiKeyCleared: false, permissionsCleared: false, logsCleared: false)

    let alert = try #require(report.failureAlert)

    #expect(alert.message.contains("API key"))
    #expect(alert.message.contains("permissions"))
    #expect(alert.message.contains("dictation logs"))
  }
}
