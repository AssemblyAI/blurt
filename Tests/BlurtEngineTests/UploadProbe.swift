import Foundation
import Testing

@testable import BlurtEngine

/// Transcriber double that reports *when* it was called and, optionally, parks
/// after the feed ends — the two facts the chunked upload turns on and that a
/// return-value-only stub cannot show.
///
/// One type rather than two: "parks on entry" and "parks after resolving" are
/// the same double with the hold in a different place.
final class UploadProbe: TranscriberProtocol, Sendable {
  private let transcript: String
  /// Opened the moment `transcribe` is entered, so a test can wait for the
  /// request to be in flight without polling a phase that never changes. A bare
  /// `AsyncGate`, not `Gate`: the probe must *not* block on entry — it parks on
  /// the frame feed instead, which is where the production producer waits.
  private let entered = AsyncGate()
  /// Where a real request waits for inference. Only armed when the test needs to
  /// land something while the session is `.transcribing`.
  private let holding: Gate?
  private let framesDone = ValueBox(false)
  private let cancelled = ValueBox(false)
  private let completed = Counter()

  var framesFinished: Bool { framesDone.value }
  var sawCancellation: Bool { cancelled.value }
  var completions: Int { completed.value }

  init(transcript: String, holdsBeforeReturning: Bool = false) {
    self.transcript = transcript
    holding = holdsBeforeReturning ? Gate() : nil
  }

  func transcribe(
    frames: AsyncStream<Data>, sampleRate _: Int, context _: TranscriptionContext?
  ) async throws -> String {
    entered.open()
    // The session has to keep feeding the stream for the request to complete,
    // and a probe that returned early would hide one that stopped. Spelled out
    // rather than using `drainUntilAbandoned`, because the flag has to be set
    // between the two halves: this probe reports *when* the feed ended, and a
    // cancelled run must not report a feed that did end as unfinished.
    for await _ in frames {
      // Drained to the end; the frames themselves don't matter.
    }
    framesDone.value = true
    try Task.checkCancellation()
    if let holding {
      await holding.enter()
      // Sampled after the gate so the test controls when it is read; a real
      // request would have been torn down by the cancellation itself.
      cancelled.value = Task.isCancelled
    }
    _ = completed.next()
    return transcript
  }

  func waitUntilEntered() async { await entered.wait() }
  func waitUntilHolding() async { await holding?.waitUntilEntered() }
  func allowToFinish() { holding?.allowToFinish() }
}
