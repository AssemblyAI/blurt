/// When a recording starts and stops with a meeting — a pure state machine,
/// fed a probe of whether a meeting is on every few seconds. Its rules:
///
/// - With the "Auto-record meetings" switch on (`autoStart`), it **starts** on
///   the first probe that sees a meeting.
/// - It **stops** only a recording bound to a meeting — one it started, or one
///   the user started while a meeting was on (the first probe after
///   `userStarted` decides) — and only once the meeting has been gone for
///   `stopAfter` straight; a meeting back within that window resets the clock
///   (a browser letting go of the mic for a moment doesn't end the recording).
///   A recording started with no meeting on is never stopped, even if a call
///   comes and goes during it. This half works with the switch off too.
/// - If the user stops a recording while the meeting is still on, it won't
///   start another until that meeting ends.
public struct MeetingAutoRecord: Sendable {
  public enum Action: Equatable, Sendable { case none, start, stop }

  /// How often the app probes.
  public static let probeInterval: Duration = .seconds(5)

  public var stopAfter: Duration
  /// Whether the recording on now ends with the meeting.
  private var meetingBound = false
  /// The user just started a recording: the next probe binds it to the
  /// meeting if one is on.
  private var bindOnNextProbe = false
  private var suppressed = false
  private var meetingGoneSince: ContinuousClock.Instant?

  public init(stopAfter: Duration = .seconds(60)) {
    self.stopAfter = stopAfter
  }

  /// One probe: whether a meeting is on, whether Blurt is recording, and
  /// whether the switch lets it start a recording.
  public mutating func probe(
    meetingActive: Bool, recording: Bool, autoStart: Bool, now: ContinuousClock.Instant
  ) -> Action {
    if !meetingActive { suppressed = false }
    guard recording else {
      meetingBound = false
      bindOnNextProbe = false
      meetingGoneSince = nil
      guard autoStart, meetingActive, !suppressed else { return .none }
      meetingBound = true
      return .start
    }
    if bindOnNextProbe {
      bindOnNextProbe = false
      meetingBound = meetingActive
    }
    guard meetingBound, !meetingActive else {
      meetingGoneSince = nil
      return .none
    }
    let since = meetingGoneSince ?? now
    meetingGoneSince = since
    guard now - since >= stopAfter else { return .none }
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
