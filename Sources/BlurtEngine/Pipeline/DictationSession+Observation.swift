import os

// The session's observation surface — the phase stream the app renders from and
// the os_signpost instrumentation Instruments reads — split from
// `DictationSession.swift` to stay within the lint file-length budget.
extension DictationSession {
  /// Signposter for the latency-sensitive segments of a dictation. Emitted as
  /// os_signpost intervals so Instruments can time the hand-tuned hot paths
  /// live (mic/connection warm-up on press, the transcribe→paste round trip on
  /// release). `DictationPerformanceTests` guards the same paths with
  /// wall-clock budgets; these intervals are for interactive profiling.
  static let signposter = OSSignposter(
    subsystem: BlurtIdentity.subsystem, category: "DictationPipeline")
  /// Signpost interval name for the press → `.recording` startup path.
  static let pressSignpostName: StaticString = "PressStart"
  /// Signpost interval name for the release → transcribe → inject hot path.
  static let pipelineSignpostName: StaticString = "TranscribeInject"

  /// Returns the live subscription to phase changes. The stream yields the
  /// current phase immediately, then every subsequent transition. A later call
  /// supersedes this one (finishing the prior stream), so there is a single
  /// active observer at a time — which is all the app needs (one renderer).
  public func phaseStream() -> AsyncStream<PipelinePhase> {
    let (stream, continuation) = AsyncStream.makeStream(of: PipelinePhase.self)
    currentID += 1
    let id = currentID
    self.continuation?.finish()
    self.continuation = continuation
    continuation.yield(phase)
    continuation.onTermination = { [weak self] _ in
      Task { await self?.clearContinuation(id) }
    }
    return stream
  }

  /// Clears the continuation only if it's still the active one — a stream torn
  /// down after a newer `phaseStream()` superseded it must not unset the live one.
  private func clearContinuation(_ id: Int) {
    if id == currentID { continuation = nil }
  }
}
