import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

// MARK: - Fixtures

/// Transcriber double that fails without ever using the context — an
/// authorization failure that lands before the body is finished. Still pins that
/// the session recorded the press-time context for the log: `startUpload` adopts
/// it before it opens the request, so a request that fails immediately cannot
/// take the context down with it.
struct FailsBeforeContext: TranscriberProtocol {
  func transcribe(
    frames: AsyncStream<Data>, sampleRate _: Int, context _: TranscriptionContext?
  ) async throws -> String {
    for await _ in frames {
      // Drained to the end; the frames themselves don't matter.
    }
    throw AssemblyAIError.http(status: 401, message: "Invalid API key")
  }

  func warmUp() {
    // No connection to pre-open: the double never reaches a network.
  }

  /// No prompt: the double sends nothing.
  func contextPrompt(for _: TranscriptionContext?) -> String { "" }
}
