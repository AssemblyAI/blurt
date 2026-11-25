import Foundation
import Testing

@testable import BlurtEngine

/// The displayed error-log location, shown in the Settings window's Developer
/// section beside the switch that enables writing — so it has to name the file the
/// writer actually appends to.
@Suite("DictationLog.defaultErrorDisplayPath")
struct DictationErrorLogDisplayPathTests {
  @Test("abbreviates the home directory with a tilde")
  func abbreviatesHome() {
    let shown = DictationLog.defaultErrorDisplayPath
    #expect(shown.hasPrefix("~/"))
    // No absolute home path leaking into the UI (the label is selectable, and a
    // user's account name isn't wanted in a screenshot).
    #expect(!shown.contains(NSHomeDirectory()))
  }

  @Test("names the same file the writer appends to")
  func matchesTheWriteTarget() {
    #expect(DictationLog.defaultErrorDisplayPath.hasSuffix("Library/Logs/Blurt/errors.jsonl"))
    // Tilde expansion is only offered by `NSString`; Swift's `String` has no equivalent.
    // swiftlint:disable:next legacy_objc_type
    let expanded = (DictationLog.defaultErrorDisplayPath as NSString).expandingTildeInPath
    #expect(
      expanded
        == DictationLog.defaultErrorURL.path(percentEncoded: false))
  }
}
