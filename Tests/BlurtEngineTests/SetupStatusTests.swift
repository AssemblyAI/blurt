import Testing

@testable import BlurtEngine

@Suite("SetupStatus.isReady")
struct SetupStatusTests {
  @Test("no permissions and no key is not ready")
  func nothingGranted() {
    let perms = PermissionStatus(microphone: false, accessibility: false)
    #expect(!SetupStatus.isReady(permissions: perms, hasAPIKey: false))
  }

  @Test("missing microphone is not ready")
  func missingMicrophone() {
    let perms = PermissionStatus(microphone: false, accessibility: true)
    #expect(!SetupStatus.isReady(permissions: perms, hasAPIKey: true))
  }

  @Test("missing accessibility is not ready")
  func missingAccessibility() {
    let perms = PermissionStatus(microphone: true, accessibility: false)
    #expect(!SetupStatus.isReady(permissions: perms, hasAPIKey: true))
  }

  @Test("all permissions but no API key is not ready")
  func noAPIKey() {
    let perms = PermissionStatus(microphone: true, accessibility: true)
    #expect(!SetupStatus.isReady(permissions: perms, hasAPIKey: false))
  }

  @Test("all permissions and an API key is ready")
  func everythingReady() {
    let perms = PermissionStatus(microphone: true, accessibility: true)
    #expect(SetupStatus.isReady(permissions: perms, hasAPIKey: true))
  }
}
