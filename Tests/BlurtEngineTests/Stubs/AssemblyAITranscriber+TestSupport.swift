import Foundation

@testable import AssemblyAI
@testable import BlurtAssemblyAI
@testable import BlurtEngine

/// Scaffolding shared by the transcriber suites, in `Stubs/` for the same reason
/// `makeSession` is: it was copied between two suites, and the copy silently
/// dropped the `enhancedTranscripts` / `rewriteMode` pinning that keeps a test
/// off the process's real `UserDefaults`.
func makeTranscriber(
  apiKey: String?,
  // 500, not 200: the default is for the cases that must never reach the wire
  // (a missing key throws first), so a test that accidentally does reach it
  // fails rather than quietly succeeding on an empty body.
  transport: any HTTPTransport = FakeHTTPTransport { _ in (500, Data()) },
  enhancedTranscripts: Bool = true,
  rewriteMode: RewriteMode = .fast
) -> AssemblyAITranscriber {
  AssemblyAITranscriber(
    apiKeyProvider: { apiKey },
    transport: transport,
    enhancedTranscripts: { enhancedTranscripts },
    rewriteMode: { rewriteMode }
  )
}

/// Drains a canned frame feed the way a conforming transcriber must: consume it
/// to end-of-audio, then give up if the dictation was abandoned meanwhile.
///
/// The abandonment half is one line now (`TranscriberProtocol` states the rule;
/// cancellation is the whole of it since the context became a value), and that
/// is exactly why it belongs here: the deleted `firstOrAbandoned()` existed
/// because three doubles re-derived the rule in prose and two got it wrong, and
/// three of them had started re-deriving it again.
func drainUntilAbandoned(_ frames: AsyncStream<Data>) async throws {
  for await _ in frames {
    // Drained to the end; the frames themselves don't matter.
  }
  try Task.checkCancellation()
}

/// Drives one chunked dictation request off a canned frame feed — the stand-in
/// for a live capture, which is what `transcribe` takes.
func collectTranscript(
  _ transcriber: AssemblyAITranscriber,
  pcm: Data = StubPCM.aboveMinimum,
  context: TranscriptionContext? = nil
) async throws -> String {
  try await transcriber.transcribe(
    frames: .oneShot(pcm),
    sampleRate: 16_000,
    context: context
  )
}

extension AssemblyAITranscriber {
  /// The SDK client's over-cap copy guard, so a suite can trip it with a few bytes.
  var bufferedAudioByteCap: Int {
    get { client.bufferedAudioByteCap }
    set { client.bufferedAudioByteCap = newValue }
  }

  /// `makeConfig`, as the JSON the request's `config` part carries: what the
  /// wire suites assert on, key by key.
  func makeConfigData(
    sampleRate: Int,
    sttPrompt: String,
    keytermsPrompt: [String],
    customStyle: String?,
    enhanced: Bool,
    mode: RewriteMode? = nil
  ) throws -> Data {
    try JSONEncoder().encode(
      makeConfig(
        sampleRate: sampleRate,
        sttPrompt: sttPrompt,
        keytermsPrompt: keytermsPrompt,
        customStyle: customStyle,
        enhanced: enhanced,
        mode: mode
      )
    )
  }
}
