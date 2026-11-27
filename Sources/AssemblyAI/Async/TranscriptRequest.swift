import Foundation

struct TranscriptRequest: Encodable {
  enum CodingKeys: String, CodingKey {
    case audioURL = "audio_url"
    case speakerLabels = "speaker_labels"
    case speechModels = "speech_models"
  }

  let audioURL: URL
  let speakerLabels: Bool
  let speechModels: [String]

  /// Encodes every field, omitting `speech_models` when empty so callers
  /// leaving model selection to the API don't put `[]` on the wire.
  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(audioURL, forKey: .audioURL)
    try container.encode(speakerLabels, forKey: .speakerLabels)
    if !speechModels.isEmpty {
      try container.encode(speechModels, forKey: .speechModels)
    }
  }
}
