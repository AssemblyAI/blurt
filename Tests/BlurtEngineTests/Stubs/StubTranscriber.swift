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
    frames: AsyncStream<Data>, sampleRate: Int,
    resolveContext: @escaping @Sendable () async -> TranscriptionContext?
  ) async throws -> String {
    // Drain first, then resolve the context: that is the production order (the
    // config part is written after the last frame), and a stub that resolved
    // early would hide a session that stopped feeding the stream.
    for await _ in frames {}
    receivedContexts.append(await resolveContext())
    switch mode {
    case .transcript(let transcript):
      return transcript
    case .throwError(let err):
      throw err
    }
  }
}
