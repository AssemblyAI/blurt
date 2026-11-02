/// When a recording ends on its own for want of speech: once nothing has been
/// said for `after` straight, the conversation is over. Unlike
/// `MeetingAutoRecord`'s stop, this ends **any** recording — started by hand
/// or by a meeting, with the switch on or off — and needs no probe: it reads
/// only when the live transcript last heard a word. A pure value, so the rule
/// tests without a socket or a clock.
public struct RecordingQuietStop: Sendable {
  /// How long a recording may hear nothing before it stops.
  public static let after: Duration = .seconds(15 * 60)

  /// How often the app checks.
  public static let checkInterval: Duration = .seconds(5)

  public private(set) var lastHeard: ContinuousClock.Instant

  public init(now: ContinuousClock.Instant) {
    lastHeard = now
  }

  /// Something was said (or capture resumed after a pause): the clock restarts.
  public mutating func heard(at now: ContinuousClock.Instant) {
    lastHeard = now
  }

  /// Whether it has been quiet long enough to stop.
  public func isOver(now: ContinuousClock.Instant) -> Bool {
    now - lastHeard >= Self.after
  }
}
