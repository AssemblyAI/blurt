import Foundation

@testable import BlurtEngine

actor StubTranscriber: TranscriberProtocol {
  enum Mode {
    case yieldChunks([String])
    case throwError(any Error & Sendable)
  }
  private var mode: Mode

  init(mode: Mode) { self.mode = mode }

  func transcribe(samples: [Float], sampleRate: Int, context: TranscriptionContext?) async throws -> String {
    switch mode {
    case .yieldChunks(let chunks):
      return chunks.joined()
    case .throwError(let err):
      throw err
    }
  }
}
