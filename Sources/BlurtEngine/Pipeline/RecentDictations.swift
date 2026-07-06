import Foundation

/// The in-memory ring of the most recent dictations shown in the ready window's
/// "Recent" list. A pure value type — owned by the app's `AppCoordinator` and
/// projected into `ReadyView` — so the capacity and newest-first ordering are
/// unit-testable here rather than in the AppKit shell (the same split as
/// `OverlayUIState`). In-memory only: it starts empty each launch and is never
/// written to disk.
public struct RecentDictations: Equatable, Sendable {
  /// One recorded dictation: the transcript plus when it landed.
  public struct Entry: Identifiable, Equatable, Sendable {
    /// Stable identity for SwiftUI list diffing — assigned once at creation, so
    /// an entry keeps its id as newer dictations push in ahead of it.
    public let id = UUID()
    public let text: String
    public let timestamp: Date
  }

  /// How many recent dictations the list holds. The ready window reserves space
  /// for exactly this many rows.
  public static let capacity = 3

  /// Most-recent-first, capped at `capacity`.
  public private(set) var entries: [Entry] = []

  public init() {}

  /// Records a dictation made at `time`, pushing it to the front and dropping
  /// the oldest entries beyond `capacity`. `time` is injected (not read from the
  /// clock) so tests are deterministic.
  public mutating func record(_ text: String, at time: Date) {
    entries.insert(Entry(text: text, timestamp: time), at: 0)
    if entries.count > Self.capacity {
      entries.removeLast(entries.count - Self.capacity)
    }
  }
}

extension RecentDictations.Entry {
  /// The row's relative timestamp: "just now" for the first minute (the system
  /// formatter's bare "in 0 seconds" reads oddly for a dictation that just
  /// landed), then the full relative phrasing ("2 minutes ago"). `now` is
  /// injected so tests are deterministic; `locale` so they can pin the wording.
  public func relativeLabel(now: Date, locale: Locale = .autoupdatingCurrent) -> String {
    if now.timeIntervalSince(timestamp) < 60 {
      return "just now"
    }
    // Built per call rather than cached: a stored formatter would be shared
    // mutable state (RelativeDateTimeFormatter isn't Sendable), and this runs
    // for a handful of rows on a half-minute render cadence at most.
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full  // e.g. "2 minutes ago"
    formatter.locale = locale
    return formatter.localizedString(for: timestamp, relativeTo: now)
  }
}
