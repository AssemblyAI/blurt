import AVFoundation
import AppKit
import ApplicationServices
import Foundation

public struct PermissionStatus: Equatable, Sendable {
  public let microphone: Bool
  public let accessibility: Bool

  public init(microphone: Bool, accessibility: Bool) {
    self.microphone = microphone
    self.accessibility = accessibility
  }

  public var allGranted: Bool { microphone && accessibility }
}

public enum PermissionsChecker {
  public static func check() -> PermissionStatus {
    PermissionStatus(
      microphone: micGranted(),
      accessibility: AXIsProcessTrusted()
    )
  }

  private static func micGranted() -> Bool {
    AVAudioApplication.shared.recordPermission == .granted
  }

  public static func requestMicrophone() async -> Bool {
    await AVAudioApplication.requestRecordPermission()
  }

  /// Opens System Settings to Privacy › Microphone. The fallback when the in-app
  /// `requestMicrophone()` prompt can't grant access — the user declined it, or
  /// the system won't re-present it once the status is determined — so the
  /// Microphone row still has a way forward, mirroring the Accessibility row's
  /// "open Settings" flow rather than being a dead-end button.
  @MainActor
  public static func openMicrophoneSettings() {
    guard
      let url = URL(
        string:
          "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")
    else { return }
    NSWorkspace.shared.open(url)
  }

  /// Trigger the Accessibility permission flow:
  /// 1. Make a *real* AX-protected call against another app's UI tree —
  ///    this is what reliably registers Blurt in TCC on macOS 26.
  ///    `AXIsProcessTrustedWithOptions` and the system-wide query don't
  ///    appear to count as "activity" for registration purposes.
  /// 2. Show the trust prompt with an "Open System Settings" button.
  @MainActor
  public static func openAccessibilitySettings() {
    forceAccessibilityActivity()
    let prompt: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
    _ = AXIsProcessTrustedWithOptions(prompt)
  }

  /// Makes a *real* AX-protected call against another app's UI tree — what
  /// reliably registers Blurt in TCC on macOS 26, and the no-prompt first step
  /// of `openAccessibilitySettings`. Internal rather than private so the engine
  /// tests can exercise it directly, without the trust prompt that
  /// `openAccessibilitySettings` adds on top.
  @MainActor
  static func forceAccessibilityActivity() {
    // AX reads against our own pid are NOT TCC-protected — apps can always
    // read their own UI. We must target a different process so tccd sees
    // a denied request and registers Blurt in the Accessibility list.
    // `frontmostApplication` is Blurt itself when this runs from a
    // button in our own window, which is why prior versions never worked.
    let myPid = ProcessInfo.processInfo.processIdentifier
    let others = NSWorkspace.shared.runningApplications.filter {
      $0.processIdentifier > 0 && $0.processIdentifier != myPid
    }
    let target =
      others.first(where: { $0.bundleIdentifier == "com.apple.finder" })
      ?? others.first(where: { $0.activationPolicy == .regular })
      ?? others.first
    guard let pid = target?.processIdentifier else { return }
    let element = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(
      element, kAXFocusedUIElementAttribute as CFString, &value)
  }

}
