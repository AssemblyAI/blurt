import Testing

@testable import BlurtEngine

/// Records which steps a reset actually ran, and answers each one however the
/// test asks. `InstallReset` is a sweep whose every real effect is irreversible
/// and machine-wide (defaults, the Keychain item, TCC rows, the log files), so
/// the composition is what's covered here — against doubles, never the real
/// ones.
final class ResetSpy {
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
      }
    )
  }
}
