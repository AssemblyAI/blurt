/// A recording's transcript as it streams in: the turns the realtime API has
/// settled, and the one still being spoken. A value type — the app folds each
/// `LiveTurn` in and renders the result — so the bookkeeping is testable
/// without a socket.
///
/// Append-only: turns arrive in order, so a final either replaces the last
/// settled turn (a re-send) or follows it, and only the one being spoken is
/// held apart. Nothing is re-sorted per update, however long the meeting.
public struct LiveTranscript: Equatable, Sendable {
  /// The settled turns, in order.
  public private(set) var finals: [LiveTurn] = []
  /// The turn being spoken now.
  private var current: LiveTurn?

  /// What is being said right now, if anything.
  public var partial: String? { current?.transcript.trimmedNonEmpty() }

  /// The settled turns as the view draws them. With more than one speaker,
  /// one turn per change of speaker; with one, a paragraph per turn and no
  /// label — the same shapes `text` writes. Rebuilt only when a final lands,
  /// not on each partial, so the view redrawing what's being said doesn't
  /// rewalk the whole meeting.
  public private(set) var speakerTurns: [SpeakerTurn] = []

  /// The settled turns that said something. An empty final's speaker label
  /// counts for nothing, here and in `text`, so the two never disagree.
  private var spokenFinals: [LiveTurn] { finals.filter { $0.transcript.trimmedNonEmpty() != nil } }

  /// The settled text as it is saved: `Speaker A: …` paragraphs with more
  /// than one speaker — the async transcripts' shape, so the transforms read
  /// both the same way — else the plain text.
  public var text: String {
    // `speakerTurns` labels its turns only when more than one speaker spoke.
    speakerTurns.contains { $0.speaker != nil } ? SpeakerTurn.labelled(speakerTurns) : plainText
  }

  /// The settled text without speaker labels: one paragraph per turn.
  public var plainText: String {
    spokenFinals.map(\.transcript).joined(separator: "\n\n")
  }

  public init() {
    // Nothing to set up: a fresh transcript has heard no turns.
  }

  private static func speakerTurns(of spoken: [LiveTurn]) -> [SpeakerTurn] {
    guard SpeakerTurn.isMultiSpeaker(spoken.map(\.speaker)) else {
      return spoken.map { SpeakerTurn(speaker: nil, text: $0.transcript) }
    }
    var turns: [SpeakerTurn] = []
    for turn in spoken {
      if let last = turns.last, last.speaker == turn.speaker {
        turns[turns.count - 1] = SpeakerTurn(speaker: last.speaker, text: last.text + " " + turn.transcript)
      } else {
        turns.append(SpeakerTurn(speaker: turn.speaker, text: turn.transcript))
      }
    }
    return turns
  }

  /// Folds in one update from the live session.
  public mutating func apply(_ turn: LiveTurn) {
    guard turn.isFinal else {
      current = turn
      return
    }
    if current?.order == turn.order { current = nil }
    if let last = finals.last, last.order == turn.order {
      finals[finals.count - 1] = turn
    } else {
      finals.append(turn)
    }
    speakerTurns = Self.speakerTurns(of: spokenFinals)
  }
}
