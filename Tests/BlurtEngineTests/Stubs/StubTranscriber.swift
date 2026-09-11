import Foundation

@testable import BlurtEngine

actor StubTranscriber: TranscriberProtocol {
  enum Mode {
    case transcript(String)
    case throwError(any Error & Sendable)
  }
  private var mode: Mode

  /// The context handed to each `transcribe` call, in order — what the session
  /// resolved from its press-time capture and actually put on the wire. Only
  /// assertable because that capture is injected (see `testSeams`); against the
  /// real Accessibility read the value depended on whichever app happened to be
  /// frontmost during the test run.
  private(set) var receivedContexts: [TranscriptionContext?] = []

  init(mode: Mode) { self.mode = mode }

  func transcribe(
    frames: AsyncStream<Data>, sampleRate: Int, context: TranscriptionContext?
  ) async throws -> String {
    // Context first, then the feed: that is the production order now — the
    // config part leads the body, so the session must have settled the context
    // before it opens the request.
    receivedContexts.append(context)
    try await drainUntilAbandoned(frames)
    switch mode {
    case .transcript(let transcript):
      return transcript
    case .throwError(let err):
      throw err
    }
  }
}
