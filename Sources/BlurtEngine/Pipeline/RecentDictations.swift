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
    /// Stable identity for SwiftUI list diffing — a per-`RecentDictations`
    /// sequence number assigned at record time, so an entry keeps its id as
    /// newer dictations push in ahead of it.
    public let id: Int
    public let text: String
    public let timestamp: Date
  }

  /// How many recent dictations the list holds. The ready window reserves space
  /// for exactly this many rows.
  public static let capacity = 3

  /// Most-recent-first, capped at `capacity`.
  public private(set) var entries: [Entry] = []

  /// Monotonic id source, so every entry across this value's lifetime gets a
  /// distinct, stable identity even after older ones are dropped.
  private var nextID = 0

  public init() {}

  /// Records a dictation made at `time`, pushing it to the front and dropping
  /// the oldest entries beyond `capacity`. `time` is injected (not read from the
  /// clock) so tests are deterministic.
  public mutating func record(_ text: String, at time: Date) {
    entries.insert(Entry(id: nextID, text: text, timestamp: time), at: 0)
    nextID += 1
    if entries.count > Self.capacity {
      entries.removeLast(entries.count - Self.capacity)
    }
  }
}
