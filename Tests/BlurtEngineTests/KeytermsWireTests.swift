import Foundation
import Testing

@testable import BlurtEngine

/// The two steering fields of the dictation `config`, as they actually encode:
/// `KeytermsBoost` → `keyterms_prompt`, and `STTPrompt` → a single
/// `stt_prompt` string. An extension of the `HTTPClientTests` suite in its own
/// file, exactly as the `APIKeyValidator` cases are — with its own private
/// helper, since each of those files carries its own rather than sharing one
/// across the suite.
extension HTTPClientTests {

  @Test("config part carries the key terms as the keyterms-prompt list")
  func configIncludesKeyterms() throws {
    // The key name is the contract, and it is `keyterms_prompt` — the name the
    // route's own validation puts first (`provide only one of keyterms_prompt,
    // keyterms, or word_boost`) and the one the other STT surfaces use. This sent
    // the `word_boost` alias until 2026-09-10.
    //
    // The absence assertion is the load-bearing half: the three names are
    // mutually exclusive, so a request carrying two of them 400s before the audio
    // is read. Adding a name is never a compatible change here.
    let object = try steeringConfig(keyterms: ["AssemblyAI", "LeMUR"])
    #expect(object["keyterms_prompt"] as? [String] == ["AssemblyAI", "LeMUR"])
    #expect(object.keys.contains("word_boost") == false)
    #expect(object.keys.contains("keyterms") == false)
  }

  @Test("config part carries the prior text as one ordered prompt")
  func configIncludesOrderedTurns() throws {
    // Order is the contract too — oldest first, the prior chunk last — because
    // the model reads it as continuous text rather than a bag of strings.
    let object = try steeringConfig(prompt: "First one.\nthanks for")
    #expect(object["stt_prompt"] as? String == "First one.\nthanks for")
    // `prompt` is this same field's other name, and the route rejects a request
    // carrying both: `provide only one of stt_prompt or prompt; they are the same
    // field`. So its absence is not a stylistic choice — adding it is a 400.
    #expect(object.keys.contains("prompt") == false)
    // The array-of-turns field this replaced. Both still work and can ride the
    // same request, so sending it too would put the same prior text on the wire
    // twice rather than fail.
    #expect(object.keys.contains("conversation_context") == false)
  }

  @Test("each field encodes as the JSON type its own contract names")
  func configEncodesArraysNotBareStrings() throws {
    // The two are deliberately different shapes, and neither tolerates the
    // other's: `stt_prompt` rejects an array (`Input should be a valid string`),
    // while `keyterms_prompt` is a list even for one term. Pinned both ways round
    // — `as? String` fails against an array, and `as? [String]` proves it isn't
    // one — so a builder that returned the wrong shape fails here instead of on
    // the wire.
    let object = try steeringConfig(prompt: "thanks for", keyterms: ["Blurt"])
    #expect(object["stt_prompt"] as? String == "thanks for")
    #expect(object["stt_prompt"] as? [String] == nil)
    #expect(object["keyterms_prompt"] as? [String] == ["Blurt"])
    #expect(object["keyterms_prompt"] as? String == nil)
  }

  @Test("context and key terms ride the same request")
  func configCarriesContextAndKeytermsTogether() throws {
    // Siblings, not alternatives: prior dialogue and a vocabulary list steer
    // transcription differently, and the API takes both at once.
    let object = try steeringConfig(prompt: "thanks for", keyterms: ["Blurt"])
    #expect(object["stt_prompt"] as? String == "thanks for")
    #expect(object["keyterms_prompt"] as? [String] == ["Blurt"])
  }

  @Test("config part never sets a language, leaving detection to the model")
  func configOmitsLanguageCode() throws {
    // Absence is the decision, so it is asserted rather than assumed. The
    // documented field is `language_codes` — plural, an array, which the
    // reference says defaults to `["en"]`. The singular `language_code` is
    // absent from the docs but still answered with a 200 rather than the
    // `Extra inputs are not permitted` a bogus key earns (measured 2026-09-11),
    // which makes it a **legacy alias on its way out**, not a supported
    // alternative — the same shape as `prompt`, `keyterms` and `word_boost`.
    // Both spellings are pinned absent here, and the undocumented one is the
    // one it would be most tempting to reach for.
    //
    // The documented `["en"]` default does not describe the behaviour. Measured
    // 2026-09-11 with a synthesized Spanish clip, all three came back as correct
    // Spanish in both `text` and `llm_response`: no language field,
    // `language_codes: ["es"]`, and `language_codes: ["en"]`. Even *explicitly*
    // asking for English did not force English — so on this route the field does
    // not appear to constrain the output at all, and omission is not a bet on a
    // default. Setting it can only take working detection away.
    //
    // Measured against the live endpoint instead of reasoned about: with neither
    // field set, Spanish, French, German and Japanese clips each came back
    // correctly transcribed in their own language, and the cleanup rewrite left
    // the language alone. Re-measured with `stt_prompt` in play (2026-09-10): a
    // Spanish clip still came back in Spanish with an English prompt, a Spanish
    // one, and none at all. So the managed default detects, and setting a language
    // here would only take that away.
    let object = try steeringConfig()
    #expect(object.keys.contains("language_code") == false)
    #expect(object.keys.contains("language_codes") == false)
    #expect(object.keys.sorted() == ["channels", "llm_instruction", "sample_rate"])
  }

  @Test("config part omits each steering field when it has nothing to say")
  func configOmitsEmptySteeringFields() throws {
    // Omission, not `[]`/`""`: an empty `keyterms_prompt` asks to boost nothing
    // and an empty `stt_prompt` claims the audio follows an empty string, so
    // `DictationConfig.encode(to:)` drops both keys. One empty state each to
    // test, because both builders return plain non-optional values.
    let object = try steeringConfig()
    #expect(object.keys.contains("keyterms_prompt") == false)
    #expect(object.keys.contains("stt_prompt") == false)
  }

  @Test("the cleanup instruction encodes as the key the route reads it from")
  func rewriteInstructionEncodesUnderItsOwnKey() throws {
    // Pinned against the encoder directly because the nil arm is unreachable
    // through `makeConfigData`: it needs a shipped instruction over the cap,
    // which `CleanupInstructionTests` forbids.
    #expect(try rewriteKeys("do the thing") == ["llm_instruction"])
    #expect(try rewriteConfig("do the thing")["llm_instruction"] as? String == "do the thing")
    // Nil **omits** the key, and omission is not declining: measured against
    // `/v1/transcribe/live` on 2026-09-10, a config carrying neither
    // `llm_instruction` nor `llm` still comes back with `llm_response` set to a
    // default-cleaned transcript. So this row is "the service's wording", not
    // "no rewrite" — which is fine, because the config no longer tries to
    // decline (`AssemblyAITranscriber.transcript(from:)` chooses instead).
    #expect(try rewriteKeys(nil) == [])
  }

  // MARK: - helpers

  /// The encoded `config` part re-parsed as a dictionary. The transport answers
  /// every request with a 500 because nothing here goes to the wire — these
  /// assertions are about what `makeConfigData` encodes. Enhanced transcripts
  /// are pinned on rather than left to the production default, which would read
  /// the process's real `UserDefaults`.
  private func steeringConfig(prompt: String = "", keyterms: [String] = []) throws
    -> [String: Any]
  {
    let config = try AssemblyAITranscriber(
      apiKeyProvider: { "test-key" },
      transport: FakeHTTPTransport { _ in (500, Data()) },
      enhancedTranscripts: { true },
      customStyle: { nil }
    )
    .makeConfigData(sampleRate: 16_000, sttPrompt: prompt, keytermsPrompt: keyterms)
    return try #require(JSONSerialization.jsonObject(with: config) as? [String: Any])
  }

  /// One config carrying `llmInstruction` and nothing else optional, re-parsed.
  private func rewriteConfig(_ instruction: String?) throws -> [String: Any] {
    let data = try JSONEncoder().encode(
      AssemblyAITranscriber.DictationConfig(
        sampleRate: 16_000, channels: 1, sttPrompt: "", keytermsPrompt: [],
        llmInstruction: instruction))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  /// The rewrite-related keys an instruction puts on the wire — the
  /// always-present `sample_rate` and `channels` subtracted, so the expectation
  /// reads as that argument's own contribution.
  private func rewriteKeys(_ instruction: String?) throws -> [String] {
    try rewriteConfig(instruction).keys.filter { !["sample_rate", "channels"].contains($0) }
      .sorted()
  }
}
