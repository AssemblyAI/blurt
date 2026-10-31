import BlurtEngine
import SwiftUI

/// A transcript's speaker turns: each a block with the speaker's name in their
/// colour above what they said, on a faint wash of that colour — so who's
/// talking reads at a glance. Speakers take colours in the order they first
/// speak, from system colours that adapt to dark mode; a turn no speaker was
/// told apart for ("unknown") draws in grey. Lazily stacked: a long meeting's
/// hundreds of turns are laid out only as they scroll into view.
struct SpeakerTurnsView: View {
  let turns: [SpeakerTurn]
  /// The words being spoken now, from a live recording: shown last, dimmed.
  var partial: String?

  /// The system colours speakers take, in order.
  static let palette: [Color] = [.blue, .orange, .purple, .pink, .teal, .indigo, .brown, .mint]

  var body: some View {
    let colors = Self.colors(for: turns)
    LazyVStack(alignment: .leading, spacing: 6) {
      ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
        if let speaker = turn.speaker {
          TurnBlock(name: Self.name(of: speaker), text: turn.text, color: colors[speaker] ?? .secondary)
        } else {
          Text(turn.text).textSelection(.enabled).padding(.horizontal, 8)
        }
      }
      if let partial {
        Text(partial).foregroundStyle(.secondary).padding(.horizontal, 8)
      }
    }
  }

  /// A label the realtime stream uses for a turn it couldn't attribute.
  private static func isUnattributed(_ speaker: String) -> Bool { speaker.uppercased() == "UNKNOWN" }

  /// What a turn's label reads as.
  static func name(of speaker: String) -> String {
    isUnattributed(speaker) ? "Unknown speaker" : "Speaker \(speaker)"
  }

  /// Each speaker's colour, by order of first appearance; unattributed turns
  /// take none, and so draw in grey.
  static func colors(for turns: [SpeakerTurn]) -> [String: Color] {
    var colors: [String: Color] = [:]
    for speaker in turns.compactMap(\.speaker) where colors[speaker] == nil && !isUnattributed(speaker) {
      colors[speaker] = palette[colors.count % palette.count]
    }
    return colors
  }
}

/// One turn: the name in the speaker's colour, the words beneath, on a wash
/// of the colour — the same padding on every turn keeps the text aligned.
private struct TurnBlock: View {
  let name: String
  let text: String
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(name)
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
      Text(text)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}
