import XCTest

/// What `performAccessibilityAudit()` checks on the Mac: element detection
/// and hit regions, the two macOS audits that report on this app's own views.
/// The macOS SDK offers six types (contrast, element detection, hit region,
/// sufficient element description, action, parent/child); the other four are
/// subtracted because every finding they raise is framework or system
/// behaviour, re-tested against the whole suite below on 2026-11-24 (macOS 26
/// runner, the audits run with each category included and every issue listed):
///
/// - `.contrast`: every finding is text in the system's secondary label colour
///   (captions, row subtitles, "Not connected"), whose on-screen contrast macOS
///   manages through vibrancy, or text in a window behind the one in front —
///   the audit reads every window, and AppKit dims an inactive window's text by
///   design (the wizard's "API Key", "Microphone" behind Settings). Darkening
///   the captions would fight the native idiom.
/// - `.sufficientElementDescription`: raised only by the hosting groups
///   SwiftUI wraps each window's content in, and the runner's Touch Bar. Not
///   interactive and carrying no information, so there is nothing to describe.
/// - `.action`: raised on every SwiftUI `Picker` pop-up (Settings' key, sound,
///   voice, speed, microphone and mode pickers), every toolbar `Menu` (the
///   Library's Filter, a transcript's View) and the system's "emoji & symbols"
///   control: AppKit exposes them as pop-ups that open with `AXShowMenu`, which
///   the check doesn't count. VoiceOver opens them fine.
/// - `.parentChild`: raised on the same hosting groups, often with no element
///   to name — an AX-snapshot inconsistency that survives the audit's own
///   retries, a framework bug, not this app's hierarchy.
///
/// Re-run with a category included when the SDK or the runner's macOS moves:
/// drop it from the list below and read what the audit lists.
private let auditedTypes: XCUIAccessibilityAuditType = .all.subtracting([
  .contrast, .sufficientElementDescription, .action, .parentChild,
])

/// The audit the `*AccessibilityAuditUITests` suites run on each screen they
/// visit.
extension BlurtUITestCase {
  /// The element an issue is about, as its identifier, label, title and frame.
  private static func name(_ element: XCUIElement?) -> String {
    guard let element else {
      return "no element"
    }
    guard element.exists else {
      return "an element since gone"
    }
    return "\(element.elementType) '\(element.identifier)' '\(element.label)' '\(element.title)' at \(element.frame)"
  }

  /// Audits the whole app as it stands — every window, the menu bar's menu
  /// and the overlay pill included — collecting each issue into `found` under
  /// `screen` rather than failing on the first, so one run names every issue
  /// on every screen a test visits. Issues raised by the UI-test harness's own
  /// window are skipped: it is test scaffolding, never shipped.
  ///
  /// A pass XCTest times out on reports nothing, so it runs again, afresh
  /// (`rerunsTimedOutAudit`).
  func audit(_ screen: String, into found: inout [String]) throws {
    let harness = app.windows[UITestIdentifiers.harnessWindowTitle]
    let harnessFrame = harness.exists ? harness.frame : .null
    var reruns = 0
    while true {
      var issues: [String] = []
      do {
        try app.performAccessibilityAudit(for: auditedTypes) { issue in
          if let element = issue.element, element.exists, harnessFrame.contains(element.frame) {
            return true
          }
          issues.append(
            "[\(screen)] \(issue.compactDescription): \(issue.detailedDescription) — \(Self.name(issue.element))"
          )
          return true
        }
        found += issues
        return
      } catch {
        guard Self.rerunsTimedOutAudit(after: error, reruns: &reruns) else {
          throw error
        }
      }
    }
  }

  /// Whether `audit` should run a pass again: XCTest gave up reading the
  /// app's accessibility hierarchy (`Code=-56`, "Audit failed to complete in
  /// time") — no finding, only a reading that never came — and it hasn't
  /// already been run again twice. The iPhone audits hit this on a busy CI
  /// simulator (`AccessibilityAuditTests+Timeout.swift`); a window the audit
  /// can never read still fails on the third.
  private static func rerunsTimedOutAudit(after error: any Error, reruns: inout Int) -> Bool {
    let failure = error as NSError
    let timedOut = failure.domain == "com.apple.xcode.xctest.accessibilityAudit" && failure.code == -56
    guard timedOut, reruns < 2 else {
      return false
    }
    reruns += 1
    Thread.sleep(forTimeInterval: 2)  // wall-clock-ok: a UI test: the app under test runs on real time
    return true
  }

  /// Fails once per issue `found` holds, each on its own line, so a CI log
  /// (which shows a failure's first line) names every one.
  func assertNoAccessibilityIssues(_ found: [String]) {
    continueAfterFailure = true
    for issue in found { XCTFail(issue) }
  }
}
