import Foundation

extension Date {
  /// How long after a moment `relativeLabel` keeps saying "just now", in
  /// seconds — the smallest unit it shows above this is minutes.
  ///
  /// Public because a list's timestamp refresh cadence is chosen against it:
  /// a view redrawing slower than this leaves rows stale. Published rather
  /// than restated so the two can't drift.
  public static let justNowThreshold: TimeInterval = 60

  /// A row's relative timestamp: `justNow` for the first minute (the system
  /// formatter's bare "in 0 seconds" reads oddly for something that just
  /// landed), then the full relative phrasing ("2 minutes ago"). `now` is
  /// injected so tests are deterministic; `locale` so they can pin the wording.
  public func relativeLabel(
    now: Date, justNow: String = "just now", locale: Locale = .autoupdatingCurrent
  ) -> String {
    if now.timeIntervalSince(self) < Self.justNowThreshold {
      return justNow
    }
    // Built per call rather than cached: a stored formatter would be shared
    // mutable state (RelativeDateTimeFormatter isn't Sendable), and this runs
    // for a handful of rows on a half-minute render cadence at most.
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full  // e.g. "2 minutes ago"
    formatter.locale = locale
    return formatter.localizedString(for: self, relativeTo: now)
  }
}
