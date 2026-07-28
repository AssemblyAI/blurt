import Foundation
import Testing

@testable import BlurtEngine

/// The gate on the launch-time update check. It lives in the engine precisely so
/// these cases are covered: `UpdateCheckModel`, which applies it, has no test
/// target, so a launch gate written inline there would be checked by nobody —
/// and its failure modes are quiet ones (a check that never runs, or one that
/// runs on every relaunch).
@Suite("AutomaticUpdateCheck")
struct AutomaticUpdateCheckTests {
  /// A fixed "now" so the arithmetic is deterministic; the absolute value is
  /// irrelevant, only the distances from it.
  private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

  @Test("a configured app that has never checked checks")
  func firstEverCheck() {
    #expect(AutomaticUpdateCheck.shouldRun(isConfigured: true, lastCheck: nil, now: now))
  }

  @Test("setup still unfinished never checks")
  func unconfiguredNeverChecks() {
    // The point of the gate: no update modal thrown over the setup wizard, and
    // nothing to update to before the app even works. True regardless of when a
    // check last ran.
    #expect(!AutomaticUpdateCheck.shouldRun(isConfigured: false, lastCheck: nil, now: now))
    #expect(
      !AutomaticUpdateCheck.shouldRun(
        isConfigured: false, lastCheck: ago(AutomaticUpdateCheck.minimumInterval * 10), now: now))
  }

  @Test("a check within the interval is skipped")
  func throttledWithinInterval() {
    // Quit-and-relaunch a few times in an afternoon and GitHub is fetched once.
    #expect(!AutomaticUpdateCheck.shouldRun(isConfigured: true, lastCheck: now, now: now))
    #expect(!AutomaticUpdateCheck.shouldRun(isConfigured: true, lastCheck: ago(60), now: now))
    #expect(
      !AutomaticUpdateCheck.shouldRun(
        isConfigured: true, lastCheck: ago(AutomaticUpdateCheck.minimumInterval - 1), now: now))
  }

  @Test("a check older than the interval runs again")
  func dueAfterInterval() {
    #expect(
      AutomaticUpdateCheck.shouldRun(
        isConfigured: true, lastCheck: ago(AutomaticUpdateCheck.minimumInterval), now: now))
    #expect(
      AutomaticUpdateCheck.shouldRun(
        isConfigured: true, lastCheck: ago(AutomaticUpdateCheck.minimumInterval * 3), now: now))
  }

  @Test("a timestamp in the future doesn't wedge the check off")
  func futureStampIsDue() {
    // Clock correction, a restored backup, or a machine that travelled back a
    // timezone can leave a stamp ahead of now. Naive subtraction would suppress
    // the check until real time caught up with the skew.
    #expect(
      AutomaticUpdateCheck.shouldRun(
        isConfigured: true, lastCheck: now.addingTimeInterval(60 * 60 * 24 * 365), now: now))
  }

  @Test("the throttle is a day and the launch wait is short")
  func policyConstants() {
    // Both numbers are judgement calls, but their scale is the policy: check
    // about daily, and don't fetch in the launch's first moments.
    #expect(AutomaticUpdateCheck.minimumInterval == 24 * 60 * 60)
    #expect(AutomaticUpdateCheck.launchDelay > .zero)
    #expect(AutomaticUpdateCheck.launchDelay < .seconds(30))
  }
}
