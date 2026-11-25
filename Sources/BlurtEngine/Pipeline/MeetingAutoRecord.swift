/// When a recording starts and stops with a meeting — a pure state machine,
/// fed a probe of whether a meeting is on every few seconds. Its rules:
///
/// - With the "Auto-record meetings" switch on (`autoStart`), it **starts** on
///   the first probe that sees a conferencing app, and on a browser call only
///   once one has been on for `browserStartAfter` straight — voice search or a
///   site's mic test lets go long before that (#345).
/// - It **stops** only a recording bound to a meeting — one it started, or one
///   the user started while a meeting was on (the first probe after
///   `userStarted` decides) — and only once the meeting has been gone for its
///   grace straight: `appStopAfter` when a conferencing app held the mic (it
///   lets go the moment the call ends, and only then), `browserStopAfter`
///   when only a browser did (a tab can let go of the mic for a moment
///   mid-call). A meeting back within that window resets the clock.
///   A recording started with no meeting on is never stopped, even if a call
///   comes and goes during it. This half works with the switch off too.
/// - If the user stops a recording while the meeting is still on, it won't
///   start another until that meeting ends.
public struct MeetingAutoRecord: Sendable {
  public enum Action: Equatable, Sendable { case noChange, start, stop }

  /// What a probe saw holding the mic: a conferencing app, or only a browser.
  public enum Meeting: Equatable, Sendable { case app, browser }

  /// How often the app probes.
  public static let probeInterval: Duration = .seconds(5)

  // MARK: - What counts as a meeting

  /// Conferencing apps whose microphone use means a call. One vendor's apps
  /// are matched by bundle-id prefix instead, which covers its helpers.
  static let conferencingBundleIDs: Set<String> = [
    "com.microsoft.teams2", "com.cisco.webexmeetingsapp", "com.apple.FaceTime",
    "com.hnc.Discord", "com.tinyspeck.slackmacgap", "com.tencent.tencentmeeting",
    "net.whatsapp.WhatsApp", "io.aircall.phone", "app.tuple.app",
  ]

  /// Browsers: a tab can't be told apart from outside, so a browser counts as
  /// a call only when it both holds the mic and plays audio — a call's
  /// two-way audio, which voice search or a mic-test page doesn't have — and
  /// starts a recording only once that has lasted (`browserStartAfter`).
  static let browserBundleIDs: Set<String> = [
    "com.google.Chrome", "com.google.Chrome.beta", "com.apple.Safari",
    "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser",
    "company.thebrowser.Browser",
  ]

  public var appStopAfter: Duration
  public var browserStopAfter: Duration
  /// How long a browser call must be on, probe after probe, before it starts
  /// a recording. A conferencing app starts one at once.
  public var browserStartAfter: Duration
  /// When the browser call on now was first seen, while not recording.
  private var browserSince: ContinuousClock.Instant?
  /// Whether the recording on now ends with the meeting.
  private var meetingBound = false
  /// The grace the meeting last seen earns once it's gone.
  private var stopAfter: Duration
  /// The user just started a recording: the next probe binds it to the
  /// meeting if one is on.
  private var bindOnNextProbe = false
  private var suppressed = false
  private var meetingGoneSince: ContinuousClock.Instant?

  public init(
    appStopAfter: Duration = .seconds(15),
    browserStopAfter: Duration = .seconds(60),
    browserStartAfter: Duration = .seconds(30)
  ) {
    self.appStopAfter = appStopAfter
    self.browserStopAfter = browserStopAfter
    self.browserStartAfter = browserStartAfter
    stopAfter = browserStopAfter
  }

  /// What meeting these microphone users mean, if any — an app over a
  /// browser when both hold the mic. `playing` is who's running audio output:
  /// a browser counts only if it's in both. Blurt's own capture is in neither
  /// list, so it never counts.
  public static func meeting(in bundleIDs: Set<String>, playing: Set<String>) -> Meeting? {
    if bundleIDs.contains(where: { $0.hasPrefix("us.zoom") }) || !bundleIDs.isDisjoint(with: conferencingBundleIDs) {
      return .app
    }
    return bundleIDs.intersection(playing).isDisjoint(with: browserBundleIDs) ? nil : .browser
  }

  /// One probe: what meeting is on (nil for none), whether Blurt is
  /// recording, and whether the switch lets it start a recording.
  public mutating func probe(
    meeting: Meeting?, recording: Bool, autoStart: Bool, now: ContinuousClock.Instant
  ) -> Action {
    let meetingActive = meeting != nil
    if let meeting { stopAfter = meeting == .app ? appStopAfter : browserStopAfter }
    if !meetingActive { suppressed = false }
    if meeting != .browser || recording { browserSince = nil }
    guard recording else {
      meetingBound = false
      bindOnNextProbe = false
      meetingGoneSince = nil
      guard autoStart, let meeting, !suppressed else {
        return .noChange
      }
      if meeting == .browser {
        let since = browserSince ?? now
        browserSince = since
        guard now - since >= browserStartAfter else {
          return .noChange
        }
        browserSince = nil
      }
      meetingBound = true
      return .start
    }
    if bindOnNextProbe {
      bindOnNextProbe = false
      meetingBound = meetingActive
    }
    guard meetingBound, !meetingActive else {
      meetingGoneSince = nil
      return .noChange
    }
    let since = meetingGoneSince ?? now
    meetingGoneSince = since
    guard now - since >= stopAfter else {
      return .noChange
    }
    meetingBound = false
    meetingGoneSince = nil
    return .stop
  }

  /// The user started a recording: it ends with the meeting if one is on.
  public mutating func userStarted() {
    meetingBound = false
    bindOnNextProbe = true
    meetingGoneSince = nil
  }

  /// The user stopped (or a start failed): no auto-stop to do, and no restart
  /// until the meeting that's on — if one is — ends.
  public mutating func userStopped(meetingActive: Bool) {
    meetingBound = false
    bindOnNextProbe = false
    meetingGoneSince = nil
    suppressed = meetingActive
  }
}
