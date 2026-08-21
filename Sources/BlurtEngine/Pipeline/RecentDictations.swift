import Foundation

/// The in-memory ring of the most recent dictations. A pure value type — owned by
/// `DictationSession` (see its `recentDictations`), pushed to the app through
/// `onTranscriptDelivered`, and projected into `ReadyView` — so the capacity and
/// newest-first ordering are unit-testable here rather than in the AppKit shell
/// (the same split as `OverlayUIState`). In-memory only: it starts empty each
/// launch and is never written to disk.
///
/// **It holds far more than it shows.** `capacity` is the history depth;
/// `displayCapacity` is how many rows the ready window's "Recent" list renders.
/// The deep end exists because a dictation's recent history is also request
/// context — `ConversationContext` sends the user's recent utterances as the
/// leading `conversation_context` turns, so "how many do we remember" is a
/// question about transcription quality, not about how tall a list looks.
public struct RecentDictations: Equatable, Sendable {
  /// One recorded dictation: the transcript plus when it landed.
  public struct Entry: Identifiable, Equatable, Sendable {
    /// How long after a dictation `relativeLabel` keeps saying "just now", in
    /// seconds — the smallest unit it shows above this is minutes.
    ///
    /// Public because the ready screen's timestamp refresh cadence is chosen
    /// against it: a view redrawing slower than this leaves rows stale. Published
    /// rather than restated so the two can't drift, the same reason
    /// `MicCapture.meterIntervalSeconds` is public.
    public static let justNowThreshold: TimeInterval = 60

    /// Stable identity for SwiftUI list diffing — assigned once at creation, so
    /// an entry keeps its id as newer dictations push in ahead of it.
    public let id = UUID()
    public let text: String
    public let timestamp: Date
    /// Display name of the **custom** style this dictation was made with (the
    /// active profile's name). `nil` otherwise — the base Default styling,
    /// enhanced transcripts off, or a host that supplies no style — which
    /// renders as just the timestamp: the base treatment is every row's
    /// default, so naming it on each would be noise.
    public let style: String?
  }

  /// How many recent dictations the ring remembers. Deliberately deeper than
  /// what the UI shows (`displayCapacity`): the history is also transcription
  /// context, and this is the number that decides how much of it the model gets.
  /// Sized against the request rather than the window — the API accepts 100
  /// `conversation_context` turns, and `ConversationContext.recentTurnCap` takes
  /// the newest 99 of these so the cursor's prior text can have the last slot.
  public static let capacity = 100

  /// How many rows the ready window's "Recent" list renders. The list area
  /// reserves space for exactly this many, so it is the number the height
  /// arithmetic below is about.
  public static let displayCapacity = 3

  /// Height a list showing a full `displayCapacity` rows occupies: every row,
  /// plus a separator *between* each adjacent pair. The ready window pins its
  /// list area to this whether it holds 0, 1, or `displayCapacity` entries, so
  /// nothing above it shifts as dictations arrive.
  ///
  /// The row metrics come from the view; what lives here is the count arithmetic,
  /// which is a fact about `displayCapacity` — including the `- 1` that a change
  /// to that number is most likely to get wrong.
  public static func reservedHeight(rowHeight: CGFloat, separatorThickness: CGFloat) -> CGFloat {
    CGFloat(displayCapacity) * rowHeight + CGFloat(displayCapacity - 1) * separatorThickness
  }

  /// Most-recent-first, capped at `capacity`.
  public private(set) var entries: [Entry] = []

  /// The newest `displayCapacity` entries — what the ready window's list renders.
  /// A projection here rather than a `prefix` at the call site, so the view can't
  /// accidentally render the whole 100-deep history now that `entries` is much
  /// longer than the list is tall.
  public var displayed: [Entry] { Array(entries.prefix(Self.displayCapacity)) }

  /// Every remembered transcript **oldest first** — the order
  /// `config.conversation_context` wants, since `entries` is newest-first for the
  /// UI. Text only: the timestamps are a display concern.
  public var transcriptsOldestFirst: [String] { entries.reversed().map(\.text) }

  public init() {}

  /// Records a dictation made at `time` with `style` (see `Entry.style`),
  /// pushing it to the front and dropping the oldest entries beyond `capacity`.
  /// `time` is injected (not read from the clock) so tests are deterministic.
  public mutating func record(_ text: String, style: String? = nil, at time: Date) {
    entries.insert(Entry(text: text, timestamp: time, style: style), at: 0)
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
    if now.timeIntervalSince(timestamp) < Self.justNowThreshold {
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
