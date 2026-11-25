import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

struct DecodedEntry: Decodable {
  /// Spelled out because the custom `init(from:)` below suppresses the synthesis
  /// that would otherwise derive these — mirroring `DictationLog.Entry`, which
  /// states its own keys for the same reason.
  enum CodingKeys: String, CodingKey {
    case transcript, ts, keyterms
    case sttPrompt = "stt_prompt"
  }

  let transcript: String
  let ts: String
  /// `stt_prompt` and `keyterms` are the two fields `Entry.encode(to:)` writes only
  /// when non-empty, so an omitted-key line has to decode rather than throw. Empty,
  /// not optional — the repo bans optional collections, and it costs nothing here:
  /// "omitted" vs "written as `[]`" is asserted on the raw line by
  /// `nilFieldsAreOmitted`, which is the level that contract actually lives at.
  let sttPrompt: String
  let keyterms: [String]

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    transcript = try container.decode(String.self, forKey: .transcript)
    ts = try container.decode(String.self, forKey: .ts)
    sttPrompt = try container.decodeIfPresent(String.self, forKey: .sttPrompt) ?? ""
    keyterms = try container.decodeIfPresent([String].self, forKey: .keyterms) ?? []
  }
}
