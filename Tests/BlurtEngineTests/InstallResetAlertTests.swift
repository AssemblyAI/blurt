import Testing

@testable import BlurtEngine

/// What a partial reset *says*. The shell has no test target, so the wording is
/// the engine's — and the thing worth pinning is that every step that failed is
/// named, since the user's only next move is knowing what survived.
@Suite("InstallReset.Report.failureAlert")
struct InstallResetAlertTests {
  @Test("a complete reset has nothing to report")
  func completeSaysNothing() {
    let report = InstallReset.Report(
      apiKeyCleared: true, permissionsCleared: true, logsCleared: true
    )
    #expect(report.failureAlert == nil)
  }

  @Test("names the step that failed")
  func namesTheFailedStep() throws {
    let report = InstallReset.Report(
      apiKeyCleared: true, permissionsCleared: false, logsCleared: true
    )

    let alert = try #require(report.failureAlert)

    #expect(alert.message.contains("permissions"))
    #expect(!alert.message.contains("API key"))
    #expect(!alert.message.contains("dictation logs"))
    #expect(!alert.title.isEmpty)
  }

  @Test("names every step that failed")
  func namesEveryFailedStep() throws {
    let report = InstallReset.Report(
      apiKeyCleared: false, permissionsCleared: false, logsCleared: false
    )

    let alert = try #require(report.failureAlert)

    #expect(alert.message.contains("API key"))
    #expect(alert.message.contains("permissions"))
    #expect(alert.message.contains("dictation logs"))
  }
}
