import BlurtEngine
import Foundation

/// A transcriber that answers every utterance with the same words, offline.
nonisolated struct StubTranscriber: TranscriberProtocol {
  let text: String

  func transcribe(frames: AsyncStream<Data>, sampleRate _: Int, context _: TranscriptionContext?) async -> String {
    for await _ in frames {
      // Drained only: the words are fixed, whatever the audio says.
    }
    return text
  }
}
