import Foundation
import os

// The post-release pipeline — transcribe → inject, plus the bounded wait on the
// press-time context read — split from `DictationSession.swift` to stay within
// the lint file-length budget, like `+Commands` and `+Observation`.
//
// It also owns the *whole* upload lifecycle, including `startUpload(frames:)`,
// which `performPress` calls: the request spans press to release, and keeping it
// beside `awaitUpload` and `resolveCapturedContext` — the two things that finish
// it — beats splitting one lifecycle across the press/release line to match the
// file names.
/// Failures the release pipeline itself raises, as opposed to the transport's
/// (`ChunkedUploadError`) or the service's (`AssemblyAIError`). Declared here
/// because this is where it is raised: filed under the transport's body-stream
/// errors it read as one, and a transport test reached for it as a stand-in.
enum DictationPipelineError: Error, LocalizedError {
  /// A release reached the transcript step with no request in flight — the
  /// recording was never uploaded.
  case uploadNeverStarted

  var errorDescription: String? {
    switch self {
    case .uploadNeverStarted:
      return "The recording wasn't uploaded."
    }
  }
}

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

  /// Takes no audio: the recording was uploaded as it was captured, so the
  /// recorded blob's only remaining job — the too-short-clip check — belongs to
  /// `performRelease`, which can abandon the request without racing it.
  func runTranscribeInject() async {
    // Times the full post-release hot path — dictation round trip plus the paste
    // (including the clipboard settle) — across every exit (empty transcript,
    // failure, cancel, or a completed paste).
    let pipelineInterval = Self.signposter.beginInterval(Self.pipelineSignpostName)
    defer { Self.signposter.endInterval(Self.pipelineSignpostName, pipelineInterval) }
    // Wait out the press-time AX field read if it is somehow still running —
    // it was started at press and bounded by `contextWaitBudget`, so by now it
    // has almost always resolved and handed itself to the request. Done here,
    // before the transcript wait, so `capturedContext` is set for the paste
    // separator and the log whether or not the request gets that far.
    await resolveCapturedContext()
    guard let text = await awaitUpload() else { return }

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
      recentDictations.record(trimmed, style: styleNameProvider(), at: Date())
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

  /// Opens the dictation request at press and streams `frames` into it.
  ///
  /// Unstructured on purpose: the request has to outlive `performPress`'s turn
  /// and stay reachable from a later `release()` or `cancel()`, which is what
  /// `uploadTask` is for. Nothing awaits it here — the whole point is that the
  /// upload runs while the user talks.
  ///
  /// The feed arrives as an argument rather than being fetched here, so it
  /// belongs to the capture `mic.start()` just brought up; see
  /// `MicCaptureProtocol.start()` for the race that shape rules out.
  ///
  /// The context travels the same direction: this installs the channel the
  /// request's `config` part waits on, and starts the task that pushes the
  /// press-time read into it as soon as that read lands. So the request is
  /// one-way throughout — context, then audio — and needs no reference back to
  /// this actor.
  ///
  /// The push happens here rather than at release because the `config` part is
  /// written before any audio: the service decodes the audio as it arrives and
  /// cannot start without the config. The value is the same one release used to
  /// send — the read is started at press either way — it just stops being held
  /// back until the recording ends.
  func startUpload(frames: AsyncStream<Data>) {
    let (context, contextFeed) = AsyncStream.makeStream(
      of: TranscriptionContext?.self, bufferingPolicy: .bufferingNewest(1))

    // Lifted out of the actor so the task body captures a Sendable value rather
    // than isolated state, the same move `performPress` makes for it.
    // `SyncSTTLimits.sampleRate` needs no such hoist — it is a static on an enum.
    let transcriber = transcriber
    upload = InFlightUpload(
      task: Task {
        try await transcriber.transcribe(
          frames: frames, sampleRate: SyncSTTLimits.sampleRate, context: context)
      },
      contextFeed: contextFeed)
    contextResolution = Task { [weak self] in await self?.forwardCapturedContext() }
  }

  /// Resolves the press-time AX field read, bounded by `contextWaitBudget`,
  /// records it as `capturedContext` for the paste's separator decision and the
  /// log, and hands it to the request's `config` part.
  ///
  /// Take the stream out of the actor's state in the SAME turn it's read, before
  /// the suspension below. Reading it and clearing it across an `await` let a
  /// cancelled pipeline clear a *newer* press's stream: a fresh `press()`
  /// installs its own `contextStream`, and a stale task's resumption would then
  /// nil that one out — so dictation #2 transcribes with `context: nil`, losing
  /// its whole `conversation_context` — the recent-dictation turns *and* the
  /// prior chunk — along with the key terms.
  private func forwardCapturedContext() async {
    let stream = contextStream
    contextStream = nil
    let resolved: TranscriptionContext?
    if let stream {
      resolved = await Self.firstValue(
        of: stream, within: Self.contextWaitBudget, clock: clock)
    } else {
      resolved = nil
    }
    // A cancelled resolution belongs to a dictation that is already over. Its
    // successor has its own, and writing this one's value here would hand
    // dictation #2 the context of #1.
    guard !Task.isCancelled else { return }
    capturedContext = resolved
    // `send` closes the channel as part of sending, which is what lets the body
    // producer write the config part and start feeding audio through.
    upload?.send(resolved)
  }

  /// Abandons the in-flight dictation request — the streamed body can't be
  /// completed meaningfully once the audio behind it is going away, so the
  /// whole request goes rather than being left to finish on its own.
  /// Reached from `setPhase` for every terminal phase, so a dictation that ends
  /// without a transcript cannot leave a request streaming. The one explicit
  /// caller left is `stopAndCancel`, which has to run before `cancelCapture()`
  /// ends the feed.
  func cancelUpload() {
    upload?.abandon()
    upload = nil
    // The resolution outlives nothing: its only two jobs are this request's
    // config part and this dictation's `capturedContext`.
    contextResolution?.cancel()
    contextResolution = nil
  }

  /// Waits for the request opened at press. Returns the transcript, or nil if
  /// it failed (phase set to `.failed`).
  private func awaitUpload() async -> String? {
    guard let inFlight = upload else {
      // Reached when a cancel cleared the handle while this task was suspended
      // in the context wait — `setPhase` abandons the upload on any terminal
      // phase, and that wait can hold for `contextWaitBudget` against an
      // unresponsive app. The cancel already claimed the phase, so leave it
      // alone: repainting it `.failed` flashes the pill red and writes a
      // developer-mode error entry for a dictation the user dismissed, the same
      // rule every other exit in this file follows.
      //
      // Without a cancel this is unreachable — `performRelease` only runs from
      // `.recording`, claimed after `startUpload()` — but a failure that
      // describes "the user spoke and nothing was uploaded" is invisible
      // otherwise, so it is surfaced rather than silently idled.
      if !Task.isCancelled {
        setPhase(.failed(.sttFailed(underlying: DictationPipelineError.uploadNeverStarted)))
      }
      return nil
    }
    // Keep the handle live across the await. `cancel()` reaches the request
    // only through it, and awaiting a `Task`'s value is *not* cancellation-aware
    // — cancelling the pipeline abandons the wait while the request runs on to
    // completion and transcribes a dictation the user already dismissed.
    //
    // Cleared only while it is still *ours*: a later press installs its own
    // upload, and clearing that one would strand a live request nothing can
    // cancel — the same trap `resolveCapturedContext` documents for
    // `contextStream`, reached here because this runs in a detached task that
    // can outlive the press that started it.
    defer { if upload?.task == inFlight.task { upload = nil } }
    do {
      return try await inFlight.task.value
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

  /// Joins the press-time context resolution so `capturedContext` is settled
  /// before the paste separator and the log read it.
  ///
  /// Awaiting a `Task`'s value is not cancellation-aware, which is safe here
  /// only because the wait inside it is bounded by `contextWaitBudget` from
  /// press — an unresponsive frontmost app cannot park the release path.
  func resolveCapturedContext() async {
    await contextResolution?.value
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
