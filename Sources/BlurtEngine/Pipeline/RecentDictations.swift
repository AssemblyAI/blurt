import Foundation

/// The in-memory ring of the most recent dictations. A pure value type — owned by
/// `DictationSession` (see its `recentDictations`), pushed to the app through
/// `onTranscriptDelivered`, and projected into `ReadyView` — so the capacity and
/// newest-first ordering are unit-testable here rather than in the AppKit shell
/// (the same split as `OverlayUIState`). In-memory only: it starts empty each
/// launch and is never written to disk.
///
/// **It holds far more than it shows.** `capacity` is the history depth;
/// `displayCapacity` is how many rows the iPhone app's "Recent" list renders.
/// The deep end exists because a dictation's recent history is also request
/// context — `STTPrompt` sends the user's recent utterances as the
/// leading lines of `stt_prompt`, so "how many do we remember" is a
/// question about transcription quality, not about how tall a list looks.
public struct RecentDictations: Equatable, Sendable {
  /// One recorded dictation: the transcript plus when it landed.
  public struct Entry: Identifiable, Equatable, Sendable {
    /// Stable identity for SwiftUI list diffing — assigned once at creation, so
    /// an entry keeps its id as newer dictations push in ahead of it.
    public let id = UUID()
    /// What was pasted, text shortcuts expanded — what the Recent row shows
    /// and copies.
    public let text: String
    /// What the service returned, before any text shortcut was expanded. This,
    /// not `text`, is what rides the next request's `stt_prompt`: a shortcut's
    /// saved replacement stays on the machine.
    let spoken: String
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
  /// Sized against the request rather than the window, but **not** against a
  /// turn limit any more: `stt_prompt` is one string with no turn concept, so
  /// `STTPrompt` has "deliberately no turn cap" and its 4096-scalar budget is
  /// the only thing that trims the history. This number therefore just bounds
  /// how much the prompt builder can draw from — it is the ring's own limit, and
  /// the scalar budget will usually bind first. It reads as 100 because the
  /// field this replaced (`conversation_context`) accepted 100 turns with the
  /// prior chunk in the last slot, which is why `ConversationContext.recentTurnCap`
  /// was 99; nothing enforces either figure now.
  public static let capacity = 100

  // periphery:ignore - public for the iOS app's Recent list (App/BlurtiOS), which the Mac scan doesn't index.
  /// How many rows the iPhone app's "Recent" list renders. The
  /// list area reserves space for exactly this many.
  public static let displayCapacity = 3

  /// Most-recent-first, capped at `capacity`.
  public private(set) var entries: [Entry] = []

  // periphery:ignore - public for the iOS app's Recent list (App/BlurtiOS), which the Mac scan doesn't index.
  /// The newest `displayCapacity` entries — what the iPhone app's list renders.
  /// A projection here rather than a `prefix` at the call site, so the view can't
  /// accidentally render the whole 100-deep history now that `entries` is much
  /// longer than the list is tall.
  public var displayed: [Entry] { Array(entries.prefix(Self.displayCapacity)) }

  /// Every remembered transcript **oldest first** — the order
  /// `config.stt_prompt` wants, since `entries` is newest-first for the
  /// UI. Text only: the timestamps are a display concern. The *spoken* text,
  /// never the expanded one — see `Entry.spoken`.
  public var spokenOldestFirst: [String] { entries.reversed().map(\.spoken) }

  public init() {}

  /// Records a dictation made at `time` with `style` (see `Entry.style`),
  /// pushing it to the front and dropping the oldest entries beyond `capacity`.
  /// `time` is injected (not read from the clock) so tests are deterministic.
  /// `spoken` is the pre-expansion transcript when text shortcuts changed it;
  /// omitted, the two are the same.
  public mutating func record(
    _ text: String, spoken: String? = nil, style: String? = nil, at time: Date
  ) {
    entries.insert(
      Entry(text: text, spoken: spoken ?? text, timestamp: time, style: style), at: 0)
    if entries.count > Self.capacity {
      entries.removeLast(entries.count - Self.capacity)
    }
  }
}

// periphery:ignore - public for the iOS app's Recent list (App/BlurtiOS), which the Mac scan doesn't index.
extension RecentDictations.Entry {
  /// The row's relative timestamp (`Date.relativeLabel`): "just now" for
  /// the first minute, then the full relative phrasing.
  public func relativeLabel(now: Date, locale: Locale = .autoupdatingCurrent) -> String {
    timestamp.relativeLabel(now: now, locale: locale)
  }
}
