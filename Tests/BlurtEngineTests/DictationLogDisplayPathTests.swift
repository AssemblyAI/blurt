import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// The displayed log location. The Settings window's Advanced pane shows this
/// beside the switch that enables writing, so it has to name the file the writer
/// actually appends to — the reason the formatting moved out of the view.
@Suite("DictationLog.defaultDisplayPath")
struct DictationLogDisplayPathTests {
  @Test("abbreviates the home directory with a tilde")
  func abbreviatesHome() {
    let shown = DictationLog.defaultDisplayPath
    #expect(shown.hasPrefix("~/"))
    // No absolute home path leaking into the UI (the label is selectable, and a
    // user's account name isn't wanted in a screenshot).
    #expect(!shown.contains(NSHomeDirectory()))
  }

  @Test("names the same file the writer appends to")
  func matchesTheWriteTarget() {
    // The whole point of deriving this next to `defaultURL`: the two can't drift.
    #expect(DictationLog.defaultDisplayPath.hasSuffix("Library/Logs/Blurt/dictations.jsonl"))
    // Tilde expansion is only offered by `NSString`; Swift's `String` has no equivalent.
    // swiftlint:disable:next legacy_objc_type
    let expanded = (DictationLog.defaultDisplayPath as NSString).expandingTildeInPath
    #expect(
      expanded
        == DictationLog.defaultURL.path(percentEncoded: false))
  }
}
