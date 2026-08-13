import Foundation
import Testing

@testable import BlurtEngine

/// The two steering fields of the dictation `config`, as they actually encode:
/// `KeytermsBoost` → `word_boost`, and `ConversationContext` → an ordered
/// `conversation_context`. An extension of the `HTTPClientTests` suite in its own
/// file, exactly as the `APIKeyValidator` cases are — with its own private
/// helper, since each of those files carries its own rather than sharing one
/// across the suite.
extension HTTPClientTests {

  @Test("config part carries the key terms as the word-boost list")
  func configIncludesKeyterms() throws {
    // The key name is the contract: `word_boost` is what the dictation API's
    // reference documents. `keyterms_prompt` is the sibling Sync surface's name
    // for the same feature and only ever reached the engine as a forwarded
    // unknown field, and the aliases are documented as mutually exclusive — so
    // sending both is what must not happen.
    let object = try steeringConfig(keyterms: ["AssemblyAI", "LeMUR"])
    #expect(object["word_boost"] as? [String] == ["AssemblyAI", "LeMUR"])
    #expect(object.keys.contains("keyterms_prompt") == false)
  }

  @Test("config part carries the conversation context as ordered turns")
  func configIncludesOrderedTurns() throws {
    // Order is the contract too — oldest first, the prior chunk last — because
    // the model reads it as a dialogue rather than a bag of strings.
    let object = try steeringConfig(turns: ["First one.", "thanks for"])
    #expect(object["conversation_context"] as? [String] == ["First one.", "thanks for"])
    // The field it replaced. Sending both would put the same prior chunk on the
    // wire twice and re-suppress `language_code`, which a custom prompt disables.
    #expect(object.keys.contains("prompt") == false)
  }

  @Test("both fields encode as JSON arrays, even holding a single value")
  func configEncodesArraysNotBareStrings() throws {
    // `conversation_context` also accepts a bare string for a single turn, so a
    // one-turn request could silently be a different JSON shape from every other
    // one. Pinned as `[String]` so it never is — `as? [String]` fails against a
    // string, and `as? String` proves it isn't one.
    let object = try steeringConfig(turns: ["thanks for"], keyterms: ["Blurt"])
    #expect(object["conversation_context"] as? [String] == ["thanks for"])
    #expect(object["conversation_context"] as? String == nil)
    #expect(object["word_boost"] as? [String] == ["Blurt"])
    #expect(object["word_boost"] as? String == nil)
  }

  @Test("context and key terms ride the same request")
  func configCarriesContextAndKeytermsTogether() throws {
    // Siblings, not alternatives: prior dialogue and a vocabulary list steer
    // transcription differently, and the API takes both at once.
    let object = try steeringConfig(turns: ["thanks for"], keyterms: ["Blurt"])
    #expect(object["conversation_context"] as? [String] == ["thanks for"])
    #expect(object["word_boost"] as? [String] == ["Blurt"])
  }

  @Test("config part omits each steering field when it has nothing to say")
  func configOmitsEmptySteeringFields() throws {
    // Omission, not `[]`: an empty `word_boost` asks to boost nothing and an
    // empty `conversation_context` claims an empty dialogue, so
    // `DictationConfig.encode(to:)` drops both keys. One empty state each to
    // test, because both builders return plain arrays.
    let object = try steeringConfig()
    #expect(object.keys.contains("word_boost") == false)
    #expect(object.keys.contains("conversation_context") == false)
  }

  // MARK: - helpers

  /// The encoded `config` part re-parsed as a dictionary. The transport answers
  /// every request with a 500 because nothing here goes to the wire — these
  /// assertions are about what `makeConfigData` encodes. Enhanced transcripts
  /// are pinned on rather than left to the production default, which would read
  /// the process's real `UserDefaults`.
  private func steeringConfig(turns: [String] = [], keyterms: [String] = []) throws
    -> [String: Any]
  {
    let config = try AssemblyAITranscriber(
      apiKeyProvider: { "test-key" },
      transport: FakeHTTPTransport { _ in (500, Data()) },
      enhancedTranscripts: { true },
      customStyle: { nil }
    )
    .makeConfigData(sampleRate: 16_000, conversationContext: turns, wordBoost: keyterms)
    return try #require(JSONSerialization.jsonObject(with: config) as? [String: Any])
  }
}
