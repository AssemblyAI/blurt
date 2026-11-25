/// A transcript as `GET /v2/transcript/{id}` returns it — only the fields read.
public struct AsyncTranscript: Decodable, Sendable, Equatable {
  public enum Status: String, Decodable, Sendable {
    case queued, processing, completed, error
  }

  /// One speaker's turn, present when `speaker_labels` was on.
  public struct Utterance: Decodable, Sendable, Equatable {
    /// The API's label: "A", "B", …
    public let speaker: String
    public let text: String
  }

  enum CodingKeys: String, CodingKey {
    case id, status, text, utterances, error
  }

  public let id: String
  public let status: Status
  public let text: String?
  /// Empty when the API sends null — without speaker labels, or before it's done.
  public let utterances: [Utterance]
  public let error: String?

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    status = try container.decode(Status.self, forKey: .status)
    text = try container.decodeIfPresent(String.self, forKey: .text)
    utterances = try container.decodeIfPresent([Utterance].self, forKey: .utterances) ?? []
    error = try container.decodeIfPresent(String.self, forKey: .error)
  }
}
