/// When the "Auto-record meetings" switch starts and stops a recording — a
/// pure state machine, fed a probe of whether a meeting is on every few
/// seconds. Its rules:
///
/// - It **starts** on the first probe that sees a meeting.
/// - It **stops** only a recording it started itself, and only once the
///   meeting has been gone for `stopAfter` straight; a meeting back within
///   that window resets the clock (a browser letting go of the mic for a
///   moment doesn't end the recording).
/// - If the user stops a recording while the meeting is still on, it won't
///   start another until that meeting ends.
public struct MeetingAutoRecord: Sendable {
  public enum Action: Equatable, Sendable { case none, start, stop }

  /// How often the app probes.
  public static let probeInterval: Duration = .seconds(5)

  public var stopAfter: Duration
  private var autoStarted = false
  private var suppressed = false
  private var meetingGoneSince: ContinuousClock.Instant?

  public init(stopAfter: Duration = .seconds(60)) {
    self.stopAfter = stopAfter
  }

  /// One probe: whether a meeting is on, and whether Blurt is recording.
  public mutating func probe(meetingActive: Bool, recording: Bool, now: ContinuousClock.Instant) -> Action {
    if !meetingActive { suppressed = false }
    guard recording else {
      autoStarted = false
      meetingGoneSince = nil
      guard meetingActive, !suppressed else { return .none }
      autoStarted = true
      return .start
    }
    guard autoStarted, !meetingActive else {
      meetingGoneSince = nil
      return .none
    }
    let since = meetingGoneSince ?? now
    meetingGoneSince = since
    guard now - since >= stopAfter else { return .none }
    autoStarted = false
    meetingGoneSince = nil
    return .stop
  }

  /// The user stopped (or a start failed): no auto-stop to do, and no restart
  /// until the meeting that's on — if one is — ends.
  public mutating func userStopped(meetingActive: Bool) {
    autoStarted = false
    meetingGoneSince = nil
    suppressed = meetingActive
  }

  // MARK: - What counts as a meeting

  /// Conferencing apps whose microphone use means a call. One vendor's apps
  /// are matched by bundle-id prefix instead, which covers its helpers.
  static let conferencingBundleIDs: Set<String> = [
    "com.microsoft.teams2", "com.cisco.webexmeetingsapp", "com.apple.FaceTime",
    "com.hnc.Discord", "com.tinyspeck.slackmacgap", "com.tencent.tencentmeeting",
    "net.whatsapp.WhatsApp", "io.aircall.phone", "app.tuple.app",
  ]

  /// Browsers: a tab can't be told apart from outside, so any browser holding
  /// the mic counts — which is how browser-based meetings are caught, and
  /// also why a website using the mic for something else counts too.
  static let browserBundleIDs: Set<String> = [
    "com.google.Chrome", "com.google.Chrome.beta", "com.apple.Safari",
    "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser",
    "company.thebrowser.Browser",
  ]

  /// Whether these microphone users mean a meeting is on. Blurt's own
  /// capture is in neither list, so it never counts.
  public static func indicatesMeeting(_ bundleIDs: Set<String>) -> Bool {
    bundleIDs.contains { $0.hasPrefix("us.zoom") }
      || !bundleIDs.isDisjoint(with: conferencingBundleIDs)
      || !bundleIDs.isDisjoint(with: browserBundleIDs)
  }
}
