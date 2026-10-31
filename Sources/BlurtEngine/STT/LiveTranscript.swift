import AssemblyAI
import Foundation

/// One speaker's turn in a transcript: who (nil when no speaker was told
/// apart) and what they said. The structured form the transcript view draws —
/// live turns come this way already; a saved labelled transcript is parsed
/// into it once (`parse`).
public struct SpeakerTurn: Sendable, Equatable {
  public let speaker: String?
  public let text: String

  public init(speaker: String?, text: String) {
    self.speaker = speaker
    self.text = text
  }

  /// A labelled transcript ("Speaker A: …" paragraphs, as `LiveTranscript` and
  /// `FileTranscriber` write it) as turns — none unless every paragraph is in
  /// that shape, so prose is never mistaken for one.
  public static func parse(_ text: String) -> [SpeakerTurn] {
    let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
    var turns: [SpeakerTurn] = []
    for paragraph in paragraphs {
      guard paragraph.hasPrefix("Speaker "), let colon = paragraph.firstIndex(of: ":") else { return [] }
      let label = paragraph[paragraph.index(paragraph.startIndex, offsetBy: 8)..<colon]
      guard !label.isEmpty, label.count <= 24, !label.contains(" ") else { return [] }
      let words = paragraph[paragraph.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      turns.append(SpeakerTurn(speaker: label == "?" ? nil : String(label), text: words))
    }
    return turns
  }

  /// Turns written back as the labelled transcript: a paragraph each.
  static func labelled(_ turns: [SpeakerTurn]) -> String {
    turns.map { "Speaker \($0.speaker ?? "?"): \($0.text)" }.joined(separator: "\n\n")
  }
}

/// A recording's transcript as it streams in: the turns the realtime API has
/// settled, and the one still being spoken. A value type — the app folds each
/// `RealtimeTurn` in and renders the result — so the bookkeeping is testable
/// without a socket.
///
/// Append-only: turns arrive in order, so a final either replaces the last
/// settled turn (a re-send) or follows it, and only the one being spoken is
/// held apart. Nothing is re-sorted per update, however long the meeting.
public struct LiveTranscript: Equatable, Sendable {
  /// The settled turns, in order.
  public private(set) var finals: [RealtimeTurn] = []
  /// The turn being spoken now.
  private var current: RealtimeTurn?

  public init() {}

  /// Folds in one update from the realtime API.
  public mutating func apply(_ turn: RealtimeTurn) {
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
  }

  /// What is being said right now, if anything.
  public var partial: String? { current?.transcript.trimmedNonEmpty() }

  /// The settled turns as the view draws them. With more than one speaker,
  /// one turn per change of speaker; with one, a paragraph per turn and no
  /// label — the same shapes `text` writes.
  public var speakerTurns: [SpeakerTurn] {
    let spoken = finals.filter { $0.transcript.trimmedNonEmpty() != nil }
    guard Set(spoken.compactMap(\.speaker)).count > 1 else {
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

  /// Whether more than one speaker was told apart.
  private var isMultiSpeaker: Bool { Set(finals.compactMap(\.speaker)).count > 1 }

  /// The settled text as it is saved: `Speaker A: …` paragraphs with more
  /// than one speaker — the async transcripts' shape, so the transforms read
  /// both the same way — else the plain text.
  public var text: String {
    isMultiSpeaker ? SpeakerTurn.labelled(speakerTurns) : plainText
  }

  /// The settled text without speaker labels: one paragraph per turn.
  public var plainText: String {
    finals.map(\.transcript).filter { $0.trimmedNonEmpty() != nil }.joined(separator: "\n\n")
  }
}

extension RealtimeTranscriber {
  /// A session as Blurt opens one: the user's key and Blurt's User-Agent.
  public static func blurt(apiKey: String) -> RealtimeTranscriber {
    RealtimeTranscriber(apiKey: apiKey, userAgent: UserAgent.current)
  }
}
