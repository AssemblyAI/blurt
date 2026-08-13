import Dispatch

// The press half of the pipeline — everything between the key going down and
// `.recording` being claimed, including the mic bring-up that `.connecting`
// covers. Split from `DictationSession.swift` to stay within the lint
// file-length budget, mirroring `+Pipeline` (the release half). Members it
// reaches are internal, not private: file-scoped access can't cross the split.
// `Dispatch`, not `Foundation`: the only thing here from outside the module is
// `contextQueue.async` (see `performPress` for why that read is off-pool).
extension DictationSession {
  func performPress() async {
    guard phase.isTerminal else { return }
    // Refuse the press before any capture begins when the host reports a
    // blocker (e.g. no API key saved): recording an utterance that can only
    // fail at transcribe time would discard the user's words after the fact.
    if let blocker = readinessCheck() {
      setPhase(.failed(blocker))
      return
    }
    // Times the startup path — the mic bring-up and the context capture that now
    // runs alongside it (plus the detached connection warm-up) — up to the moment
    // recording actually begins. Ended on both the success and failure exits
    // (`mic.start()` is the only throwing call, and it precedes `.recording`, so
    // the two ends are mutually exclusive).
    let pressInterval = Self.signposter.beginInterval(Self.pressSignpostName)
    // Claim `.connecting` before `mic.start()`: its liveness gate holds until
    // the input route actually delivers frames, which on a Bluetooth route is
    // ~1–2 s. The press must be visibly acknowledged in that window without
    // cueing the user to speak — the pill shows a warming-up state, and the
    // start chime rides the connecting→recording edge (`RecordingCueGate`), so
    // it fires only once audio is genuinely flowing. `.recording` therefore
    // keeps meaning exactly what it says.
    setPhase(.connecting)
    do {
      // Pre-open the dictation connection while the user speaks, so the first dictation after an idle
      // gap doesn't pay DNS+TCP+TLS on the transcribe hot path (~170 ms cold, measured). Detached
      // + fire-and-forget: it must never delay recording, and a failure is harmless (the request
      // just pays setup as before); warming every press is cheap since a hot pool just reuses it.
      let transcriber = transcriber
      Task.detached { await transcriber.warmUp() }
      // The mic bring-up runs as a child task so the whole context-capture chain
      // below overlaps it instead of queueing behind it. That ordering used to be
      // free — `mic.start()` returned in microseconds — but the liveness gate can
      // now hold it for `MicLiveness.bluetoothTimeout`, and every one of those
      // milliseconds was dead time the AX read could have used. Sequenced after
      // it, the read instead landed on the *release* path, where
      // `runTranscribeInject` waits up to `contextWaitBudget` for it with the
      // user watching. Now it is almost always finished before the mic is even
      // live.
      //
      // `async let`, so a cancel still reaches it: the child inherits this task's
      // cancellation, which is what `cancel()`'s `.connecting` branch relies on
      // to preempt the wait.
      async let started: Void = mic.start()
      // Capture the frontmost app (paste target). A cheap in-process AppKit read
      // on the main actor. Lifted out of the actor first (like `transcriber`
      // above) so the call is a Sendable closure rather than isolated state.
      let captureFrontmost = seams.captureFrontmost
      let captured = await captureFrontmost()
      await injector.setTargetApp(captured.flatMap { FocusCapture.runningApp(for: $0) })
      // Key terms are read synchronously at press (cheap UserDefaults read), so
      // each dictation observably re-reads Settings edits at press time.
      let keyTerms = keyTermsProvider()
      // Session history, read on the actor for the same reason: the capture below
      // runs off-actor, so what it carries has to be a value taken now.
      let recentTranscripts = recentDictations.transcriptsOldestFirst
      // Kick off the AX field-context read now, while the target field still
      // holds focus, but don't await it here: it's cross-process IPC into the
      // frontmost app (detached — off the main actor, where it froze the
      // overlay, and off this actor, where it would wedge release()/cancel()).
      // runTranscribeInject consumes the result right before transcription,
      // bounded by `contextWaitBudget` — so a slow AX target delays the
      // transcript by at most the budget, never the recording indicator.
      let (stream, contextFeed) = AsyncStream.makeStream(
        of: TranscriptionContext?.self, bufferingPolicy: .bufferingNewest(1))
      contextStream = stream
      // A Dispatch queue, not `Task.detached`: `captureFieldContext` is documented
      // as making ~6 synchronous cross-process AX round trips, each bounded only by
      // the 1 s messaging timeout, so against a beachballing frontmost app one
      // press can *block* a thread for seconds. The Swift cooperative pool is sized
      // to the core count and does not overcommit, so a few press/cancel cycles
      // against a hung app could park every cooperative thread and stall the whole
      // non-main runtime — including this actor. Dispatch overcommits, so a blocked
      // capture costs a thread instead of the pool. Same reasoning as
      // `DictationLog`'s serial queue. Concurrent so a hung capture can't delay the
      // next press's. The body is fully synchronous and captures only Sendable
      // values, so it needs no task context.
      let captureFieldContext = seams.captureFieldContext
      Self.contextQueue.async {
        let field = captureFieldContext()
        let context = TranscriptionContext(
          appName: captured?.processName,
          windowTitle: field.windowTitle,
          fieldLabel: field.fieldLabel,
          priorText: field.priorText,
          selectedText: field.selectedText,
          recentTranscripts: recentTranscripts,
          keyTerms: keyTerms,
          targetIsSecure: field.isSecure)
        contextFeed.yield(context.isEmpty ? nil : context)
        contextFeed.finish()
      }

      // Only now join the bring-up. Everything above ran while the mic was
      // coming up; the phase still flips to `.recording` only once `start()`
      // returns, so the UI never claims capture that isn't live. The cost of
      // starting the context work first is that a press whose mic fails has
      // already set the injector's target and dispatched one AX read — both
      // harmless and overwritten by the next press.
      try await started
      // A cancel that arrived during the bring-up, on the path where `start()`
      // still returned normally — the cancel landed in the window between the
      // liveness wait finishing and `.recording` being claimed, so there was
      // nothing left to interrupt. (When it lands *during* the wait, `start()`
      // throws `CancellationError` instead and the catch below owns it.)
      //
      // Either way the mic is live by now, so tear it down rather than claiming
      // `.recording` and chiming "speak now" for a capture the user has already
      // abandoned. `Task.isCancelled` is checked alongside the flag because the
      // preempting door cancels this task without setting anything else.
      if cancelRequested || Task.isCancelled {
        try? await mic.cancelCapture()
        // `consumeCancelRequest` claims `.cancelled` when the flag route was
        // used; the task-cancellation route already claimed it in `cancel()`, so
        // only fall back when nothing has.
        if !consumeCancelRequest() { setPhase(.cancelled) }
        Self.signposter.endInterval(Self.pressSignpostName, pressInterval)
        return
      }
      setPhase(.recording)
      Self.signposter.endInterval(Self.pressSignpostName, pressInterval)
      let timeout = maxRecordingSeconds
      let clock = clock
      autoReleaseTask = Task { [weak self] in
        try? await clock.sleep(for: .seconds(timeout))
        guard let self, !Task.isCancelled else { return }
        // Enqueues like a manual key-up. If a real release already ran, the
        // queued performRelease sees a non-.recording phase and drops out.
        await self.release()
      }
    } catch {
      Self.signposter.endInterval(Self.pressSignpostName, pressInterval)
      // `MicCapture.start()` throws `CancellationError` when a teardown landed
      // during its liveness wait — an unqueued `cancelCapture()`, which its own
      // doc anticipates for hosts that don't drive the mic through this session.
      // That's the user's cancel arriving by another door, not a fault: reporting
      // it as `.audioCaptureFailed` would flash the pill red *and* write a
      // developer-mode error-log entry for something nothing went wrong in. Same
      // rule `transcribe` and `inject` already follow. `.cancelled` rather than a
      // bare return, because `.connecting` is non-terminal — leaving it would
      // strand the trigger's gate and swallow the next press.
      //
      // Consumed the same way as the exit above, not just phase-set: the
      // `.connecting` branch of `cancel()` claims the phase and returns
      // *without* enqueueing `performCancel`, so this is the only place left
      // that can clear the request it recorded. Leaving it set let the flag
      // survive into the next press, which then read it after a perfectly good
      // `mic.start()` and cancelled itself.
      if error is CancellationError {
        if !consumeCancelRequest() { setPhase(.cancelled) }
        return
      }
      setPhase(.failed(.audioCaptureFailed(underlying: error)))
    }
  }
}
