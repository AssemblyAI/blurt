import Foundation
import Testing

@testable import BlurtEngine

/// The developer-mode log records the contextual prompt the transcriber reports
/// sending (`TranscriberProtocol.contextPrompt(for:)`) rather than rebuilding it,
/// so the engine needs no provider's field or limits to log it.
@Suite("DictationSession prompt log", .timeLimit(.minutes(1)))
struct DictationSessionPromptLogTests {
  /// A transcriber that reports a prompt naming the context it was given.
  private struct Reporting: TranscriberProtocol {
    let base = StubTranscriber(mode: .transcript("Hello world."))

    func transcribe(
      frames: AsyncStream<Data>, sampleRate: Int, context: TranscriptionContext?
    ) async throws -> String {
      try await base.transcribe(frames: frames, sampleRate: sampleRate, context: context)
    }

    func contextPrompt(for context: TranscriptionContext?) -> String {
      "sent after: \(context?.priorText ?? "nothing")"
    }
  }

  @Test("the logged prompt is the one the transcriber reports for the press's context")
  func logsTheReportedPrompt() async {
    let log = RecordedLog()
    let field = FocusedFieldContext(priorText: "Hi Sam,", selectedText: nil, windowTitle: nil, fieldLabel: nil)
    let session = makeSession(transcriber: Reporting(), seams: testSeams(field: field, log: log))

    await session.dictate()
    await session.awaitPipeline()

    #expect(log.transcripts.map(\.prompt) == ["sent after: Hi Sam,"])
  }
}
