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

  /// Returns a live subscription to phase changes. The stream yields the current
  /// phase immediately, then every subsequent transition. Multiple streams can be
  /// active at once, so a debug view or test observer cannot disconnect the app's
  /// renderer.
  public func phaseStream() -> AsyncStream<PipelinePhase> {
    let (stream, continuation) = AsyncStream.makeStream(of: PipelinePhase.self)
    currentID += 1
    let id = currentID
    continuations[id] = continuation
    continuation.yield(phase)
    continuation.onTermination = { [weak self] _ in
      Task { await self?.clearContinuation(id) }
    }
    return stream
  }

  /// Clears the continuation for a stream that ended.
  private func clearContinuation(_ id: Int) {
    continuations[id] = nil
  }
}
