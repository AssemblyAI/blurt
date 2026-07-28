import Foundation

/// The policy behind the *automatic* update check: whether Blurt may check on
/// its own at launch, and how long it waits before doing so.
///
/// Owned in the engine for the same reason as `SetupReadiness` — it is a rule,
/// not plumbing, and `UpdateCheckModel` (which applies it) has no test target,
/// so a launch-gate written inline there would be covered by nothing.
///
/// "Automatic" here means the *check*, never the install. A launch check that
/// finds a newer release shows the same Download/Later alert the menu command
/// does, and the user still downloads and installs the DMG themselves — the
/// manual, download-only policy documented on `UpdateChecker` is unchanged, and
/// nothing here runs in the background beyond that one launch fetch.
public enum AutomaticUpdateCheck {
  /// The floor between automatic checks. The launch check exists to notice a
  /// release within a day or so, not to poll GitHub: quitting and relaunching
  /// five times in an afternoon must not fetch five times (the unauthenticated
  /// API is rate-limited per IP), and someone who never quits Blurt is served
  /// by the menu command. Internal — callers ask `shouldRun` rather than
  /// redoing the arithmetic.
  static let minimumInterval: TimeInterval = 24 * 60 * 60

  /// How long after launch the automatic check waits before fetching.
  ///
  /// Two reasons it isn't zero. The launch path shouldn't share its first
  /// moments with a network request; and at `applicationDidFinishLaunching` the
  /// main window's `NSWindow` doesn't exist yet, so a result arriving that early
  /// would have no window to host its sheet (`UpdateCheckModel` then falls back
  /// to a nested `runModal()` loop, which has been reported as an app hang).
  public static let launchDelay: Duration = .seconds(3)

  /// Whether a launch check should run, given how far setup has got and when a
  /// check last completed.
  ///
  /// `isConfigured` is the wizard's readiness (`SetupReadiness.isReady`): an app
  /// still in setup doesn't get an update alert thrown over its wizard, and
  /// someone who hasn't finished onboarding hasn't got a working Blurt to
  /// update yet.
  public static func shouldRun(isConfigured: Bool, lastCheck: Date?, now: Date) -> Bool {
    guard isConfigured else { return false }
    // Never checked — a fresh install, or a user who has only ever used the
    // menu command's predecessor. Check.
    guard let lastCheck else { return true }
    // A stamp in the future (clock correction, a restored backup, a machine that
    // travelled back across a timezone) would otherwise wedge the check off for
    // as long as the skew lasts. Treat it as "due" rather than trusting it.
    guard lastCheck <= now else { return true }
    return now.timeIntervalSince(lastCheck) >= minimumInterval
  }
}
