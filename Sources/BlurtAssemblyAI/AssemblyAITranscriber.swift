public import AssemblyAI
public import BlurtEngine
public import Foundation

/// `TranscriberProtocol` backed by AssemblyAI's **dictation** API, through the
/// SDK's `DictationClient` — this type is Blurt's half of each request: whose
/// key, which prompt, which key terms, which cleanup instruction, which rewrite
/// model, and which of the response's two transcripts gets pasted.
///
/// The request carries a JSON `config` part plus the captured audio, and the
/// response body carries both the verbatim transcript and an LLM-rewritten
/// version with disfluencies removed, produced by applying
/// `CleanupInstruction.text` server-side.
///
/// **Every request asks for that rewrite** — `llm_instruction` rides the config
/// unconditionally, and the config carries no on/off switch at all. Which of the
/// two transcripts gets pasted is decided on the *response*, by the "enhanced
/// transcripts" setting (on by default): see `transcript(from:enhanced:)`, which also
/// states what that costs a user who has it off.
///
/// The wire contract — the route, the 120 s cap and its `/v1/transcribe`
/// fallback, and the rule that every request is one the reference describes —
/// is `DictationClient`'s, documented there, and what a recording may be is
/// `DictationLimits`'. The floor this sends with is Blurt's own
/// (`RecordingLimits.minPCMBytes`), checked against the API's by
/// `fitsRecordingLimits`; the `User-Agent` naming Blurt is `UserAgent`'s.
public struct AssemblyAITranscriber: TranscriberProtocol {
  /// Latency instrumentation for the dictation round-trip. Findable via:
  ///   log show --predicate 'subsystem == "dev.alex.blurt" && category == "Transcriber"' --last 1h
  ///
  /// Type-scoped like every other logger in the engine (`MicCapture`,
  /// `DictationLog`, `AudioRouteMonitor`) rather than a module-global, and
  /// handed to the SDK's client so its latency lines land in the same category.
  static let log = HostIdentity.current.logger("Transcriber")
  public static let defaultBaseURL = DictationClient.defaultBaseURL
  private let apiKeyProvider: @Sendable () -> String?
  /// The SDK client every request goes through. Internal and settable so tests
  /// can trip the over-cap fallback's copy guard with a few bytes.
  var client: DictationClient
  private let enhancedTranscriptsEnabled: @Sendable () -> Bool
  private let rewriteMode: @Sendable () -> RewriteMode

  /// `enhancedTranscripts` decides, per response, which of the two transcripts
  /// the route returns gets pasted — it no longer shapes the request, which
  /// always asks for the rewrite; `rewriteMode` picks the rewrite's model
  /// (`RewriteModeStore`). The style appended to the cleanup instruction is the
  /// press's, carried on the context (`TranscriptionContext.styleInstructions`)
  /// — one profile's text, never a join of several (see `StyleProfileStore`).
  /// Both settings are read at every `transcribe` so a settings change applies
  /// to the next dictation without rebuilding the transcriber. `nil` (the
  /// default) reads the corresponding store — spelled as optionals rather than
  /// default closures because a public default argument can't reference a
  /// store's non-public member.
  @preconcurrency
  public init(
    apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.current },
    baseURL: @escaping @Sendable () -> URL = { Self.defaultBaseURL },
    transport: any HTTPTransport = URLSession.shared,
    enhancedTranscripts: (@Sendable () -> Bool)? = nil,
    rewriteMode: (@Sendable () -> RewriteMode)? = nil
  ) {
    assert(Self.fitsRecordingLimits, "RecordingLimits must fit the dictation API's DictationLimits")
    self.apiKeyProvider = apiKeyProvider
    self.client = DictationClient(
      baseURL: baseURL,
      transport: transport,
      userAgent: UserAgent.current,
      minimumAudioBytes: RecordingLimits.minPCMBytes,
      log: Self.log
    )
    self.enhancedTranscriptsEnabled = enhancedTranscripts ?? { EnhancedTranscriptsStore().isEnabled }
    self.rewriteMode = rewriteMode ?? { RewriteModeStore().mode }
  }

  /// Whether the engine's recording policy (`RecordingLimits`) fits what the
  /// dictation API accepts (`DictationLimits`): the same sample rate, a cap no
  /// longer than the API's, and a floor no shorter than the one below which it
  /// transcribes nothing. The engine names no provider, so this is where its
  /// numbers meet AssemblyAI's: asserted when a transcriber is built, and pinned
  /// by `RecordingLimitsTests`.
  static let fitsRecordingLimits =
    RecordingLimits.sampleRate == DictationLimits.sampleRate
    && RecordingLimits.maxAudioSeconds <= DictationLimits.maxAudioSeconds
    && RecordingLimits.minAudioSeconds >= DictationLimits.minAudioSeconds

  // MARK: - Dictation request

  /// `config.stt_prompt` for `context` (`STTPrompt`): what the request sends,
  /// and what the developer-mode log records.
  public func contextPrompt(for context: TranscriptionContext?) -> String {
    STTPrompt.text(context: context)
  }

  public func transcribe(
    frames: AsyncStream<Data>,
    sampleRate: Int,
    context: TranscriptionContext?
  ) async throws -> String {
    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
      throw BlurtError.apiKeyMissing
    }
    // What goes on the wire is the prior text (recent dictations, then the
    // text before the cursor) and the key terms as keyterms prompting. App name,
    // window title, field label and selected text stay on the machine —
    // `STTPrompt` draws that line, so nothing is filtered here.
    // Read once, so a mid-recording flip can't split the request from the paste.
    let enhanced = enhancedTranscriptsEnabled()
    // Read once too: the instruction is chosen per mode, and the paste checks the
    // rewrite against the instruction that was actually sent.
    let mode = instructionMode(enhanced: enhanced)
    let config = makeConfig(
      sampleRate: sampleRate,
      sttPrompt: contextPrompt(for: context),
      keytermsPrompt: KeyTerms.fitted(context?.keyTerms ?? []),
      customStyle: context?.styleInstructions,
      enhanced: enhanced,
      mode: mode
    )
    let response: DictationResponse
    do {
      response = try await client.transcribe(frames: frames, config: config, apiKey: apiKey)
    } catch AssemblyAIError.audioTooShort {
      // The engine's one name for "below the floor", which it idles on quietly.
      throw TranscriberError.audioTooShort
    }
    return transcript(
      from: response,
      enhanced: enhanced,
      instruction: cleanupInstruction(appending: context?.styleInstructions, mode: mode)
    )
  }

  /// Pre-opens the dictation host's connection (`DictationClient.warmUp()`).
  public func warmUp() async {
    await client.warmUp()
  }

  /// Builds the `config` part sent alongside the audio. Both steering
  /// fields are included only when non-empty: an empty `sttPrompt`
  /// omits `stt_prompt` (no prior text, so the model works from the audio alone
  /// and the service's managed default prompt applies) and an empty
  /// `keytermsPrompt` omits `keyterms_prompt` (which would otherwise ask to boost
  /// nothing). `prompt` is `stt_prompt`'s other name and must never ride
  /// alongside it — see `STTPrompt`. The cleanup instruction is
  /// `cleanupInstruction()`'s and rides every request, whatever the
  /// enhanced-transcripts setting says — that switch is applied to the response,
  /// in `transcript(from:enhanced:)`. Internal so tests can assert the
  /// config wiring without inspecting the multipart upload body.
  /// Neither steering field is defaulted: every caller states both, so what a
  /// given request does and does not steer with is readable at the call site
  /// rather than inferred from which argument was left off.
  /// `enhanced` is the request's one reading of the setting, which the paste
  /// uses too. `mode` is the model the rewrite runs on (`instructionMode`), which
  /// picks the instruction; nil reads it now, for callers with no paste to keep in
  /// step.
  func makeConfig(
    sampleRate: Int,
    sttPrompt: String,
    keytermsPrompt: [String],
    customStyle: String?,
    enhanced: Bool,
    mode: RewriteMode? = nil
  ) -> DictationConfig {
    let resolvedMode = mode ?? instructionMode(enhanced: enhanced)
    return DictationConfig(
      sampleRate: sampleRate,
      channels: 1,
      sttPrompt: sttPrompt,
      keytermsPrompt: keytermsPrompt,
      llmInstruction: cleanupInstruction(appending: customStyle, mode: resolvedMode),
      // Only while the rewrite is pasted: off, a slower model only adds latency.
      rewriteMode: enhanced ? resolvedMode.wireValue : nil
    )
  }

  /// The cleanup instruction this request asks the route to rewrite with. Returning
  /// nil would leave the wording to the service — which is *not* the same as no
  /// rewrite; see `DictationConfig.llmInstruction` — and is the one-line revert
  /// should the shipped instruction ever need pulling.
  ///
  /// `customStyle` is the press's style (`TranscriptionContext.styleInstructions`);
  /// `mode` picks the instruction tuned for the model that will apply it.
  private func cleanupInstruction(appending customStyle: String?, mode: RewriteMode) -> String? {
    CleanupInstruction.sendable(appending: customStyle, mode: mode)
  }

  /// The model the rewrite will actually run on, for choosing its instruction. With
  /// enhanced transcripts off no `rewrite_mode` is sent, so the service runs Fast.
  private func instructionMode(enhanced: Bool) -> RewriteMode {
    enhanced ? rewriteMode() : .fast
  }
}
