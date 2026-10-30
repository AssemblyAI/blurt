import Foundation

/// Cuts a selection into the pieces `SelectionSpeaker` reads one request at a
/// time (`AssemblyAISpeechSynthesizer`), rewriting each for listening first
/// when skip-jargon is on. Reading starts after the first piece — kept short
/// (`firstMaxCharacters`) so its rewrite and first audio come back quickly —
/// and the rest are asked for only as the listening reaches them.
///
/// Whole paragraphs are packed into a chunk while they fit; a paragraph too
/// long for one is cut at sentence ends (`SpeechSegmenter`), so a chunk never
/// starts or ends mid-sentence and the rewrite sees whole thoughts.
enum ListeningChunks {
  /// Big enough that a chunk is a few paragraphs (a minute or two of speech),
  /// small enough that its rewrite comes back in a second or two.
  static let maxCharacters = 1_500
  /// The first piece's limit: about a paragraph, the wait before the first word.
  static let firstMaxCharacters = 400

  static func chunks(
    of text: String, maxCharacters: Int = maxCharacters, firstMaxCharacters: Int = firstMaxCharacters
  ) -> [String] {
    var chunks: [String] = []
    var current = ""
    var limit: Int { chunks.isEmpty ? min(firstMaxCharacters, maxCharacters) : maxCharacters }
    for paragraph in text.split(separator: "\n\n", omittingEmptySubsequences: true) {
      let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let pieces =
        trimmed.count <= limit ? [trimmed] : SpeechSegmenter.segments(of: trimmed, maxCharacters: limit)
      for (index, piece) in pieces.enumerated() {
        let separator = current.isEmpty ? "" : (index == 0 ? "\n\n" : " ")
        if current.count + separator.count + piece.count > limit, !current.isEmpty {
          chunks.append(current)
          current = piece
        } else {
          current += separator + piece
        }
      }
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }
}
