import Foundation
import os

// The post-release pipeline — transcribe → inject, plus the bounded wait on
// the press-time context read — split from `DictationSession.swift` to stay
// within the lint file-length budget, like `+Commands` and `+Observation`.
extension DictationSession {
  /// The longest `runTranscribeInject` waits for the press-time AX
  /// field-context read before transcribing without it. In the common case the
  /// read finished while the user was speaking and the buffered stream hands
  /// the context straight back; against an unresponsive frontmost app the
  /// capture's serial AX round trips (each capped at ~1 s — see
  /// `FocusCapture`) could otherwise stall the transcript for several seconds.
  /// The context is best-effort priming, so past this budget the transcript
  /// (slightly less primed) beats the wait.
  static let contextWaitBudget: Duration = .milliseconds(500)

  func runTranscribeInject(pcm: Data) async {
    // Times the full post-release hot path — dictation round trip plus the paste
    // (including the clipboard settle) — across every exit (short-clip no-op,
    // empty transcript, failure, cancel, or a completed paste).
    let pipelineInterval = Self.signposter.beginInterval(Self.pipelineSignpostName)
    defer { Self.signposter.endInterval(Self.pipelineSignpostName, pipelineInterval) }
    // A clip too short for the STT model (an accidental brief tap) would only
    // earn a 400 — drop it as a silent no-op, like an empty transcript, rather
    // than calling the API and surfacing an error.
    guard pcm.count >= SyncSTTLimits.minPCMBytes else {
      // A cancel() racing the freshly spawned pipeline task already claimed the
      // phase — don't overwrite .cancelled with .idle.
      if !Task.isCancelled { setPhase(.idle) }
      return
    }

    // Resolve the press-time AX field read now that it's actually needed —
    // waiting at most `contextWaitBudget` (see its doc), so a hung read costs
    // the transcript its priming, not multiple seconds of stall.
    // Take the stream out of the actor's state in the SAME turn it's read, before
    // the suspension below. Reading it and clearing it across an `await` let a
    // cancelled pipeline clear a *newer* press's stream: `cancel()` detaches this
    // task while it's parked in `firstValue`, a fresh `press()` installs its own
    // `contextStream`, and this task's resumption then nils that one out — so
    // dictation #2 transcribes with `context: nil`, losing its whole
    // `conversation_context` — the recent-dictation turns *and* the prior chunk —
    // along with the key terms. The window is microseconds, but the invariant is
    // now local instead of depending on scheduling.
    let stream = contextStream
    contextStream = nil
    if let stream {
      capturedContext = await Self.firstValue(
        of: stream, within: Self.contextWaitBudget, clock: clock)
    } else {
      capturedContext = nil
    }

    // The dictation API runs the cleanup rewrite server-side, so the text it
    // returns is already the final, polished text — there is no client-side
    // styling pass.
    guard let text = await transcribe(pcm: pcm) else { return }

    // A cancel() that landed while transcribe was in flight already set
    // .cancelled and detached this task — don't inject or touch the phase.
    if Task.isCancelled { return }

    guard let trimmed = text.trimmedNonEmpty() else {
      setPhase(.idle)
      return
    }

    seams.logTranscript(text, capturedContext)
    // Remember it as context for the *next* press before handing it on: the ring
    // is what supplies `conversation_context`'s leading turns, so a stretch of
    // dictation continues itself. Recorded here rather than by the host so the
    // history the request is built from is the same value the "Recent" list shows.
    //
    // Unless this went into a password field. `FocusCapture` already refuses to
    // *read* a secure field; remembering what was dictated *into* one would leak
    // the same secret the other way — replayed as a context turn on every later
    // dictation this launch, in unrelated apps. So a secure target is transcribed
    // and pasted as normal, and simply not remembered.
    if capturedContext?.targetIsSecure != true {
      recentDictations.record(trimmed, at: Date())
    }
    // Report every produced transcript (trimmed for display), with the ring it
    // just joined, before injection — pasted, copied, and failed-to-paste all count.
    onTranscriptDelivered?(trimmed, recentDictations)
    await inject(text)
  }

  /// The first value of `stream`, or nil once `budget` elapses on `clock` —
  /// the race behind the bounded context wait above. Both racers respond to
  /// cancellation (an `AsyncStream` iteration ends when its task is cancelled,
  /// unlike awaiting a `Task.value`, which would leave the group joined to a
  /// hung AX read), so the losing child always winds down and the group drains.
  static func firstValue(
    of stream: AsyncStream<TranscriptionContext?>, within budget: Duration,
    clock: any Clock<Duration>
  ) async -> TranscriptionContext? {
    await withTaskGroup(of: TranscriptionContext?.self) { group in
      group.addTask {
        for await value in stream { return value }
        return nil
      }
      group.addTask {
        try? await clock.sleep(for: budget)
        return nil
      }
      let winner = await group.next() ?? nil
      group.cancelAll()
      return winner
    }
  }

  /// Runs the single dictation request. Returns the transcript, or nil if it
  /// failed (phase set to `.failed`).
  private func transcribe(pcm: Data) async -> String? {
    do {
      return try await transcriber.transcribe(
        pcm: pcm, sampleRate: SyncSTTLimits.sampleRate, context: capturedContext)
    } catch {
      // A cancel() that landed mid-request already tore this task down and set
      // .cancelled; the transport then surfaces a cancellation-shaped error
      // (URLError(.cancelled) / CancellationError). Leave the claimed phase
      // alone rather than repainting the user's cancel as a red failure.
      if Task.isCancelled || error is CancellationError { return nil }
      if let blurtError = error as? BlurtError {
        // e.g. `.apiKeyMissing` — surface it directly rather than burying it
        // inside `.sttFailed`.
        setPhase(.failed(blurtError))
      } else {
        setPhase(.failed(.sttFailed(underlying: error)))
      }
      return nil
    }
  }

  private func inject(_ text: String) async {
    setPhase(.injecting)
    do {
      try await injector.insert(
        text, after: capturedContext?.priorText, windowTitle: capturedContext?.windowTitle)
      // A cancel() that landed in insert's final, non-cancellable stretch
      // (after its last checkCancellation) already set .cancelled — leave the
      // claimed phase alone rather than repainting it as .pasted.
      if Task.isCancelled { return }
      // The paste landed — show the quiet "pasted" notice (the mirror of the
      // "copied" notice below) rather than snapping straight back to idle.
      setPhase(.pasted)
    } catch {
      // A cancel() landed mid-paste: it already set .cancelled (the injector
      // bails via its checkCancellation). Leave the claimed phase alone —
      // including on a late non-cancellation error — rather than relabeling
      // the user's cancel as a failure.
      if error is CancellationError || Task.isCancelled { return }
      guard let err = error as? BlurtError else {
        // An untyped injection error: nothing was left on the clipboard, so this
        // stays a genuine (reported) failure under the generic lost-target label.
        setPhase(.failed(.targetAppLost))
        return
      }
      // Which injector errors are a quiet "copied" notice rather than a fault is
      // `BlurtError.isQuietDegradation` — an exhaustive switch over the cases, so a
      // new error that leaves the transcript on the clipboard has to be classified
      // there instead of silently flashing red here. Everything else surfaces its
      // real error (e.g. `.accessibilityPermissionMissing`) rather than being
      // relabeled as a lost target.
      setPhase(err.isQuietDegradation ? .noTarget : .failed(err))
    }
  }
}
