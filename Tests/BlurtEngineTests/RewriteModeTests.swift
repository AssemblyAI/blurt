import AssemblyAI
import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// The rewrite mode's decode rule, store round-trip, and what each mode puts on
/// the wire as `rewrite_mode`.
@Suite("RewriteMode")
struct RewriteModeTests {
  @Test("defaults to smart when unset")
  func defaultsToSmart() {
    // An install that never touched the picker gets the larger rewrite model;
    // one that explicitly chose Fast keeps it (see `roundTrips`).
    #expect(RewriteModeStore(defaults: freshDefaults()).mode == .smart)
    #expect(RewriteMode.fromPersisted("") == .smart)
  }

  @Test("persists and reads back a chosen mode")
  func roundTrips() {
    let defaults = freshDefaults()
    RewriteModeStore(defaults: defaults).mode = .smart
    #expect(RewriteModeStore(defaults: defaults).mode == .smart)
    RewriteModeStore(defaults: defaults).mode = .fast
    #expect(RewriteModeStore(defaults: defaults).mode == .fast)
  }

  @Test("an unknown stored value falls back to smart")
  func unknownFallsBack() {
    let defaults = freshDefaults()
    defaults.set("Turbo", forKey: RewriteModeStore.defaultsKey)
    #expect(RewriteModeStore(defaults: defaults).mode == .smart)
    // The wire spelling is not the persisted one, so it must not decode either:
    // "fast" is unknown and reads as the default, not as Fast.
    #expect(RewriteMode.fromPersisted("fast") == .smart)
  }

  @Test("every mode names itself distinctly")
  func labelsAreDistinct() {
    #expect(Set(RewriteMode.allCases.map(\.label)).count == RewriteMode.allCases.count)
    #expect(!RewriteMode.guidance.isEmpty)
  }

  @Test("fast omits rewrite_mode, so a Fast request is unchanged")
  func fastOmitsTheKey() throws {
    let object = try config(mode: .fast)
    #expect(object.keys.contains("rewrite_mode") == false)
    #expect(object.keys.sorted() == ["channels", "llm_instruction", "sample_rate"])
  }

  @Test("smart sends rewrite_mode as \"smart\"")
  func smartSendsTheKey() throws {
    #expect(try config(mode: .smart)["rewrite_mode"] as? String == "smart")
  }

  @Test("smart is not requested while enhanced transcripts are off")
  func smartOmittedWhenRewriteIsDiscarded() throws {
    // The rewrite is discarded unread with the setting off, so asking for the
    // slower model would only cost latency.
    let object = try config(mode: .smart, enhancedTranscripts: false)
    #expect(object.keys.contains("rewrite_mode") == false)
  }

  @Test("the SDK writes each typed mode as its documented spelling")
  func sdkSpellsEachMode() throws {
    for mode in [DictationRewriteMode.fast, .smart] {
      let data = try JSONEncoder().encode(
        DictationConfig(
          sampleRate: 16_000,
          channels: 1,
          sttPrompt: "",
          keytermsPrompt: [],
          llmInstruction: nil,
          rewriteMode: mode
        )
      )
      let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(object["rewrite_mode"] as? String == mode.rawValue)
    }
    #expect(DictationRewriteMode.smart.rawValue == "smart")
  }

  @Test("the setting is read once per request, so a mid-recording flip can't split request from paste")
  func enhancedReadOncePerRequest() async throws {
    // On when the request opened, off by the time it answered: the request asked
    // for the rewrite, so the rewrite is what gets pasted.
    let reads = Mutex(0)
    let transport = FakeHTTPTransport { _ in (200, Data(#"{"text":"um hello","llm_response":"Hello."}"#.utf8)) }
    let transcriber = AssemblyAITranscriber(
      apiKeyProvider: { "test-key" },
      transport: transport,
      enhancedTranscripts: {
        reads.withLock { readCount in
          readCount += 1
          return readCount == 1
        }
      },
      rewriteMode: { .smart }
    )
    #expect(try await collectTranscript(transcriber) == "Hello.")
    #expect(reads.withLock { $0 } == 1)
  }

  /// Each mode is sent the instruction tuned on its own model: Smart's, measured on the
  /// Voice Arena public set, scored worse than Fast's own when run on Fast.
  @Test("each mode is sent its own cleanup instruction", arguments: RewriteMode.allCases)
  func instructionFollowsTheMode(mode: RewriteMode) throws {
    let object = try config(mode: mode)
    #expect(object["llm_instruction"] as? String == CleanupInstruction.base(for: mode))
  }

  /// With enhanced transcripts off no `rewrite_mode` goes on the wire, so the service
  /// runs Fast — and Fast's instruction must go with it, whatever the setting says.
  @Test("with enhanced transcripts off, Fast's instruction is sent even when Smart is chosen")
  func unenhancedSendsTheFastInstruction() throws {
    let object = try config(mode: .smart, enhancedTranscripts: false)
    #expect(object["llm_instruction"] as? String == CleanupInstruction.text)
    #expect(object["rewrite_mode"] == nil)
  }

  /// `transcribe` reads the mode once and hands it over; the config must not
  /// read the setting again, or a flip in between sends one mode's instruction
  /// with the other mode's `rewrite_mode`.
  @Test("the mode a request was given is the one on the wire, not a fresh read of the setting")
  func givenModeIsTheOneSent() throws {
    let data = try makeTranscriber(apiKey: "test-key", rewriteMode: .fast)
      .makeConfigData(
        sampleRate: 16_000, sttPrompt: "", keytermsPrompt: [], customStyle: nil, enhanced: true, mode: .smart
      )
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["rewrite_mode"] as? String == DictationRewriteMode.smart.rawValue)
    #expect(object["llm_instruction"] as? String == CleanupInstruction.base(for: .smart))
  }

  // MARK: - helpers

  private func config(mode: RewriteMode, enhancedTranscripts: Bool = true) throws -> [String: Any] {
    let data = try makeTranscriber(
      apiKey: "test-key", enhancedTranscripts: enhancedTranscripts, rewriteMode: mode
    )
    .makeConfigData(
      sampleRate: 16_000, sttPrompt: "", keytermsPrompt: [], customStyle: nil, enhanced: enhancedTranscripts
    )
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
