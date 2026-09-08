import Foundation

@testable import BlurtEngine

/// Scaffolding shared by the transcriber suites, in `Stubs/` for the same reason
/// `makeSession` is: it was copied between two suites, and the copy silently
/// dropped the `enhancedTranscripts` / `customStyle` pinning that keeps a test
/// off the process's real `UserDefaults`.
func makeTranscriber(
  apiKey: String?,
  // 500, not 200: the default is for the cases that must never reach the wire
  // (a missing key throws first), so a test that accidentally does reach it
  // fails rather than quietly succeeding on an empty body.
  transport: any HTTPTransport = FakeHTTPTransport { _ in (500, Data()) },
  enhancedTranscripts: Bool = true,
  customStyle: String? = nil
) -> AssemblyAITranscriber {
  AssemblyAITranscriber(
    apiKeyProvider: { apiKey }, transport: transport,
    enhancedTranscripts: { enhancedTranscripts },
    customStyle: { customStyle })
}

/// Drives one chunked dictation request off a canned frame feed — the stand-in
/// for a live capture, which is what `transcribe` takes.
func collectTranscript(
  _ transcriber: AssemblyAITranscriber,
  pcm: Data = StubPCM.aboveMinimum,
  context: TranscriptionContext? = nil
) async throws -> String {
  try await transcriber.transcribe(
    frames: .oneShot(pcm), sampleRate: 16_000, context: .oneShot(context))
}
