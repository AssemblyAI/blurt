import Foundation
import Testing

@testable import BlurtEngine

/// The word-boost half of the dictation `config` contract: `KeytermsBoost` →
/// the request's `keyterms_prompt`. An extension of the `HTTPClientTests` suite
/// in its own file, exactly as the `APIKeyValidator` cases are — with its own
/// private helper, since each of those files carries its own rather than sharing
/// one across the suite.
extension HTTPClientTests {

  @Test("config part carries the key terms as the word-boost list")
  func configIncludesKeyterms() throws {
    // The key name is the contract, and the wrong one is worse than a rename
    // elsewhere: `word_boost` is deprecated and *rejected* by the model family
    // the service runs, so it would fail the whole request rather than degrade.
    let object = try keytermsConfig(keyterms: ["AssemblyAI", "LeMUR"])
    #expect(object["keyterms_prompt"] as? [String] == ["AssemblyAI", "LeMUR"])
    #expect(object.keys.contains("word_boost") == false)
  }

  @Test("prompt and key terms ride the same request")
  func configCarriesPromptAndKeytermsTogether() throws {
    // Siblings, not alternatives: prose context and a vocabulary list steer
    // transcription differently, and the API takes both at once.
    let object = try keytermsConfig(prompt: "Previous transcript:\nthanks for", keyterms: ["Blurt"])
    #expect(object["prompt"] as? String == "Previous transcript:\nthanks for")
    #expect(object["keyterms_prompt"] as? [String] == ["Blurt"])
  }

  @Test("config part omits the keyterms field when there are no terms")
  func configOmitsKeyterms() throws {
    // Omission, not `[]`: an empty list on the wire asks to boost nothing, so
    // `DictationConfig.encode(to:)` drops the key. One empty state to test,
    // because `KeytermsBoost.fitted` returns a plain array.
    #expect(try keytermsConfig(keyterms: []).keys.contains("keyterms_prompt") == false)
  }

  // MARK: - helpers

  /// The encoded `config` part re-parsed as a dictionary. The transport answers
  /// every request with a 500 because nothing here goes to the wire — these
  /// assertions are about what `makeConfigData` encodes. Enhanced transcripts
  /// are pinned on rather than left to the production default, which would read
  /// the process's real `UserDefaults`.
  private func keytermsConfig(prompt: String? = nil, keyterms: [String]) throws -> [String: Any] {
    let config = try AssemblyAITranscriber(
      apiKeyProvider: { "test-key" },
      transport: FakeHTTPTransport { _ in (500, Data()) },
      enhancedTranscripts: { true },
      customStyle: { nil }
    )
    .makeConfigData(sampleRate: 16_000, prompt: prompt, keyterms: keyterms)
    return try #require(JSONSerialization.jsonObject(with: config) as? [String: Any])
  }
}
