import Foundation
import Testing

@testable import BlurtEngine

@Suite("PermissionsChecker")
struct PermissionsCheckerTests {

  @Test("allGranted requires both microphone and accessibility")
  func allGrantedLogic() {
    #expect(PermissionStatus(microphone: true, accessibility: true).allGranted)
    #expect(!PermissionStatus(microphone: true, accessibility: false).allGranted)
    #expect(!PermissionStatus(microphone: false, accessibility: true).allGranted)
    #expect(!PermissionStatus(microphone: false, accessibility: false).allGranted)
  }

  @Test("PermissionStatus is value-equatable")
  func equatable() {
    #expect(
      PermissionStatus(microphone: true, accessibility: false)
        == PermissionStatus(microphone: true, accessibility: false))
    #expect(
      PermissionStatus(microphone: true, accessibility: false)
        != PermissionStatus(microphone: false, accessibility: false))
  }

  @Test("check returns the current status without prompting")
  func checkReturnsStatus() {
    // We can't assert the actual grant state (it depends on the test host's TCC
    // record), only that the read-only check runs and produces a consistent
    // struct. This covers check(), micGranted(), and the AXIsProcessTrusted call.
    let status = PermissionsChecker.check()
    #expect(status.allGranted == (status.microphone && status.accessibility))
  }

  @Test("forceAccessibilityActivity runs without prompting")
  @MainActor
  func forceAccessibilityActivityRuns() {
    // Best-effort, side-effect-light (a read-only AX query against another
    // process); it must not throw or prompt. This is the no-prompt half of the
    // Accessibility flow — `openAccessibilitySettings` adds the trust prompt.
    PermissionsChecker.forceAccessibilityActivity()
  }
}
