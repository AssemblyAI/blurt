import Foundation
import XCTest

extension AccessibilityAuditTests {
  /// How many times one audit pass is run again after XCTest gives up on it.
  private static let auditTimeoutRetries = 2

  /// Lets `audit` run a pass again when XCTest timed out reading the screen,
  /// rather than fail the test on a reading that never happened; any other
  /// error, or a timeout past `auditTimeoutRetries`, is rethrown.
  ///
  /// `performAccessibilityAudit` reads the app's accessibility hierarchy from
  /// the simulator and throws `Code=-56` ("Audit failed to complete in time")
  /// when that read doesn't come back. A timeout is no finding, about this app
  /// or any other: it says only that the simulator was too busy to answer. On
  /// CI it hit a different screen each time, all at the heaviest moments —
  /// just after launch (`testConsent`, `testSetupWithKey`) and with the
  /// keyboard up (`testTryItBox`) — on PRs that changed no iPhone code, and on
  /// a merge-queue run of `main`, while the same commits passed on a re-run.
  /// A screen the simulator can never read still fails, after the retries.
  static func retryAfterTimeout(_ error: any Error, timeouts: inout Int) throws {
    let audit = error as NSError
    guard
      audit.domain == "com.apple.xcode.xctest.accessibilityAudit", audit.code == -56,
      timeouts < auditTimeoutRetries
    else {
      throw error
    }
    timeouts += 1
    Thread.sleep(forTimeInterval: 2)  // wall-clock-ok: a UI test: the simulator it waits on runs on real time
  }
}
