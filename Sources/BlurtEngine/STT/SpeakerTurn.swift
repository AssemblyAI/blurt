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
  ///
  /// None, too, unless more than one speaker is named: both writers label a
  /// transcript only then (`isMultiSpeaker`), so a monologue is saved as plain
  /// text — and plain text that merely opens "Speaker notes: …" is prose, not a
  /// turn by a speaker called "notes".
  public static func parse(_ text: String) -> [Self] {
    let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
    var turns: [Self] = []
    for paragraph in paragraphs {
      guard paragraph.hasPrefix("Speaker "), let colon = paragraph.firstIndex(of: ":") else {
        return []
      }
      let label = paragraph[paragraph.index(paragraph.startIndex, offsetBy: 8)..<colon]
      guard !label.isEmpty, label.count <= 24, !label.contains(" ") else {
        return []
      }
      let words = paragraph[paragraph.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      turns.append(Self(speaker: label == "?" ? nil : String(label), text: words))
    }
    return isMultiSpeaker(turns.map(\.speaker)) ? turns : []
  }

  /// Whether more than one speaker was told apart among `labels` — the rule
  /// for labelling a transcript's turns at all, live or async: a monologue
  /// reads better without a label on every paragraph.
  package static func isMultiSpeaker(_ labels: [String?]) -> Bool {
    Set(labels.compactMap(\.self)).count > 1
  }

  /// Turns written back as the labelled transcript: a paragraph each.
  package static func labelled(_ turns: [Self]) -> String {
    turns.map { "Speaker \($0.speaker ?? "?"): \($0.text)" }.joined(separator: "\n\n")
  }
}
