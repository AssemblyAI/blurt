import os

// The session's observation surface — the one place a phase change is published
// (`setPhase`), the phase stream the app renders from, and the os_signpost
// instrumentation Instruments reads — split from `DictationSession.swift` to stay
// within the lint file-length budget.
extension DictationSession {
  /// Signposter for the latency-sensitive segments of a dictation. Emitted as
  /// os_signpost intervals so Instruments can time the hand-tuned hot paths
  /// live (mic/connection warm-up on press, the transcribe→paste round trip on
  /// release). `DictationPerformanceTests` guards the same paths with
  /// wall-clock budgets; these intervals are for interactive profiling.
  static let signposter = OSSignposter(
    subsystem: HostIdentity.current.subsystem, category: "DictationPipeline"
  )
  /// Signpost interval name for the press → `.recording` startup path.
  static let pressSignpostName: StaticString = "PressStart"
  /// Signpost interval name for the release → transcribe → inject hot path.
  static let pipelineSignpostName: StaticString = "TranscribeInject"

  /// Returns a live subscription to phase changes. The stream yields the current
  /// phase immediately, then every subsequent transition. Multiple streams can be
  /// active at once, so a debug view or test observer cannot disconnect the app's
  /// renderer.
  ///
  /// `alreadyShowing` is the phase the subscriber already renders: when the
  /// session is still at it, the opening yield is skipped. A coordinator that
  /// subscribes from an unstructured task takes commands meanwhile, so a
  /// replayed opening phase could land after a press it already accepted —
  /// a fresh session's `.idle`, which is terminal, ended the iPhone's first
  /// dictation that way (#413). Compared here, on the actor, as the
  /// subscription is taken, the stale phase is never queued; a phase the
  /// session moved to first still opens the stream.
  public func phaseStream(alreadyShowing shown: PipelinePhase? = nil) -> AsyncStream<PipelinePhase> {
    let (stream, continuation) = AsyncStream.makeStream(of: PipelinePhase.self)
    currentID += 1
    let id = currentID
    continuations[id] = continuation
    if phase != shown {
      continuation.yield(phase)
    }
    continuation.onTermination = { [weak self] _ in
      Task { await self?.clearContinuation(id) }
    }
    return stream
  }

  /// Clears the continuation for a stream that ended.
  private func clearContinuation(_ id: Int) {
    continuations[id] = nil
  }

  /// Sets the phase on behalf of the press in progress: a failure is logged
  /// against `pressContext`. Right for everything on the press side — the
  /// command queue holds the actor for that press, so no other press can have
  /// installed its own — and never used by the post-release pipeline, which
  /// names its press with `setPhase(_:for:)`.
  func setPhase(_ newPhase: PipelinePhase) {
    setPhase(newPhase, for: pressContext)
  }

  /// Sets the phase, logging a failure against `press`'s field context.
  ///
  /// `press` is the dictation the phase belongs to, decided by the caller
  /// rather than read here: the pipeline task outlives its press's turn on the
  /// actor, and a cancel ends the phase without waiting for it, so by the time a
  /// late failure lands `pressContext` may be a newer press's. The pipeline
  /// passes the `PressContext` it was spawned with.
  func setPhase(_ newPhase: PipelinePhase, for press: PressContext?) {
    // Every failure route funnels through here — the press-time readiness
    // refusal, both `mic` failures, the transcribe catch, and the injector's
    // typed and untyped errors — so the developer-mode error log is written from
    // this one place rather than at each `setPhase(.failed(…))` call site. A
    // failure path added later is logged by construction instead of by someone
    // remembering. The non-error outcomes stay out of it by the same token:
    // `.noTarget` (the quiet "copied" notice, explicitly "don't report it") and
    // `.cancelled` aren't `.failed`, so they never reach this branch.
    //
    // Gated on developer mode inside `DictationLog.appendError` behind the seam,
    // which also dispatches the file I/O off this actor — the log must not make a
    // failure slower to show.
    if case .failed(let error) = newPhase {
      seams.logFailure(error, press?.resolved)
    }
    // The same construction argument, for the same reason: a dictation that
    // reaches a terminal phase without a transcript must not leave a request
    // streaming, or the service transcribes audio nobody is waiting for. Spelled
    // out at each exit it was five near-identical reminders, and the next
    // terminal exit added would have silently missed it.
    //
    // Safe as a blanket rule because a terminal phase and a live upload are
    // mutually exclusive by definition: the only phase set between
    // `startUpload(frames:)` and `awaitUpload`'s hand-off is `.transcribing`,
    // which is not terminal, and on the way out the handle is already cleared
    // before `.pasted` / `.noTarget` are claimed.
    if newPhase.isTerminal {
      cancelUpload()
    }
    phase = newPhase
    for continuation in continuations.values {
      continuation.yield(newPhase)
    }
  }
}
