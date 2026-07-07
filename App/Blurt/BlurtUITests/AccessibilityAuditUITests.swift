import XCTest

/// Runs `XCUIApplication.performAccessibilityAudit()` on each screen. The audit
/// auto-flags hit-target size, clipped/overlapping text, element detection, and
/// trait problems — enforcing the a11y investment the app already makes (overlay
/// VoiceOver announcements, menu-bar labels, control identifiers) at near-zero
/// cost. Any surviving issue is reported as a test failure.
///
/// Scoped to the high-signal, reliably-actionable checks (element detection, hit
/// region, dynamic type, clipped text, trait). The app is clean on all of them —
/// a regression would flag e.g. a new unlabeled control, a tiny hit target, or
/// clipped text. The four categories subtracted from `.all` are the ones that,
/// on SwiftUI-for-macOS, report framework/system artifacts rather than app
/// defects — running them would be permanently red for reasons nothing in this
/// codebase can fix:
///
/// - `.contrast`: captions/help text use the system secondary label color, whose
///   on-screen contrast macOS manages via vibrancy; the audit's static luminance
///   check flags every such caption. Darkening them would fight the native idiom.
/// - `.sufficientElementDescription`: SwiftUI layout containers (`Group`) and the
///   system TouchBar surface as description-less elements. They're not
///   interactive and carry no information, so there's nothing to describe.
/// - the macOS-only "action is missing" / "parent-child mismatch" checks: the
///   former fires on decorative keycap capsules SwiftUI tags with an action-ish
///   trait but no action; the latter is an AX-snapshot inconsistency that
///   survives the audit's own retries — a framework bug, not our hierarchy.
private let auditedTypes: XCUIAccessibilityAuditType = .all.subtracting([
  .contrast, .sufficientElementDescription, .action, .parentChild,
])

final class AccessibilityAuditUITests: BlurtUITestCase {
  /// The setup wizard / ready screen. Only the harness presents at launch in
  /// UI-test mode, so open the main window from it before auditing.
  func testMainWindowAccessibility() throws {
    let harness = harnessWindow()
    harness.buttons[UITestIdentifiers.openMainButton].click()
    XCTAssertTrue(
      app.windows[UITestIdentifiers.mainWindowTitle].waitForExistence(timeout: 10),
      "Main window did not appear")
    try app.performAccessibilityAudit(for: auditedTypes)
  }

  /// The Settings window (API key, hotkey, sound, key terms).
  func testSettingsAccessibility() throws {
    openSettingsWindow()
    try app.performAccessibilityAudit(for: auditedTypes)
  }
}
