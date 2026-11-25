import Foundation

struct TranscriptRequest: Encodable {
  enum CodingKeys: String, CodingKey {
    case audioURL = "audio_url"
    case speakerLabels = "speaker_labels"
  }

  let audioURL: URL
  let speakerLabels: Bool
}
