import Foundation

@testable import BlurtEngine

actor StubTranscriber: TranscriberProtocol {
  enum Mode {
    case transcript(String)
    case throwError(any Error & Sendable)
  }
  private var mode: Mode

  init(mode: Mode) { self.mode = mode }

  func transcribe(pcm: Data, sampleRate: Int, context: TranscriptionContext?) async throws -> String {
    switch mode {
    case .transcript(let transcript):
      return transcript
    case .throwError(let err):
      throw err
    }
  }
}
