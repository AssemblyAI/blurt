import Foundation
import Testing

@testable import BlurtEngine

/// Transcriber stub that signals when `transcribe` is entered and then blocks
/// until released, so a `cancel()` can be landed deterministically while the
/// session is suspended in `.transcribing`. Gate choreography lives in `Gate`.
actor GatedTranscriber: TranscriberProtocol {
  private let text: String
  /// When true, a release that arrives after the task was cancelled throws
  /// `URLError(.cancelled)` — mimicking the real URLSession-backed transcriber,
  /// whose in-flight request is torn down by task cancellation.
  private let throwsWhenCancelled: Bool
  /// When true, a release throws `URLError(.cancelled)` whether or not the task
  /// was cancelled — a request the system dropped, which nobody cancelled.
  private let throwsCancelled: Bool
  private let gate = Gate()

  init(text: String, throwsWhenCancelled: Bool = false, throwsCancelled: Bool = false) {
    self.text = text
    self.throwsWhenCancelled = throwsWhenCancelled
    self.throwsCancelled = throwsCancelled
  }

  func transcribe(
    frames: AsyncStream<Data>, sampleRate _: Int, context _: TranscriptionContext?
  ) async throws -> String {
    try await drainUntilAbandoned(frames)
    await gate.enter()
    if throwsCancelled || (throwsWhenCancelled && Task.isCancelled) { throw URLError(.cancelled) }
    return text
  }

  func warmUp() {
    // No connection to pre-open: the stub never reaches a network.
  }

  func waitUntilStarted() async { await gate.waitUntilEntered() }
  func allowToFinish() { gate.allowToFinish() }
}
