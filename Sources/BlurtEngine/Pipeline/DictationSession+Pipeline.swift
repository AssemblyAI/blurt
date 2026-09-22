import Foundation
import os

// The post-release pipeline — transcribe → inject, plus the bounded wait on the
// press-time context read — split from `DictationSession.swift` to stay within
// the lint file-length budget, like `+Commands` and `+Observation`.
//
// It also owns the *whole* upload lifecycle, including `startUpload(frames:)`,
// which `performPress` calls: the request spans press to release, and keeping it
// beside `awaitUpload` — the thing that finishes it — beats splitting one
// lifecycle across the press/release line to match the file names.
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
  /// The longest `startUpload` waits for the press-time AX field-context read
  /// before opening the request without it.
  ///
  /// It bounds the *start of the upload* rather than the release path, because
  /// the streaming route puts `config` first: the context has to be settled
  /// before any audio can move. That is a better place for the wait than the one
  /// it replaced — the read is dispatched before the mic bring-up is even joined
  /// (`beginContextCapture`), so it is almost always finished before the mic is
  /// live and this hands the value straight back, and whatever it does cost is
  /// spent while the user is still speaking instead of while they wait for a
  /// transcript. Nothing is lost meanwhile: `frames` buffers, so the audio is
  /// still captured, just uploaded from slightly further behind.
  ///
  /// Against an unresponsive frontmost app the capture's serial AX round trips
  /// (each capped at ~1 s — see `FocusCapture`) could otherwise hold the upload
  /// for several seconds, and a request that opens that late has a backlog it
  /// never clears. The context is best-effort priming, so past this budget the
  /// audio moving (slightly less primed) beats the wait.
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
    // No context step here any more: `startUpload` resolved the press-time AX
    // read before it opened the request, because the streaming route needs the
    // `config` part first. So `capturedContext` — which the paste separator and
    // the log below both read — was set while the user was still speaking, and
    // the release path goes straight to the transcript. This is the second half
    // of the latency win: the old shape spent up to `contextWaitBudget` here,
    // with the user watching the pill.
    guard let text = await awaitUpload() else { return }

    // A cancel() that landed while transcribe was in flight already set
    // .cancelled and detached this task — don't inject or touch the phase.
    if Task.isCancelled { return }

    guard text.trimmedNonEmpty() != nil else {
      setPhase(.idle)
      return
    }

    // The log keeps what the service returned; everything downstream — the
    // ring, the host's Recent list, the paste — sees the expanded text, so the
    // history shows what actually landed in the target.
    seams.logTranscript(text, capturedContext)
    let expanded = TextShortcutExpander.expand(text, using: textShortcutsProvider())
    guard let trimmed = expanded.trimmedNonEmpty() else {
      setPhase(.idle)
      return
    }
    // Remember it as context for the *next* press before handing it on: the ring
    // is what supplies `stt_prompt`'s leading text, so a stretch of
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
    await inject(expanded)
  }

  /// Opens the dictation request at press and streams `frames` into it.
  ///
  /// Unstructured on purpose: the request has to outlive `performPress`'s turn
  /// and stay reachable from a later `release()` or `cancel()`, which is what
  /// `upload` is for. Nothing awaits it here — the whole point is that the
  /// upload runs while the user talks.
  ///
  /// The feed arrives as an argument rather than being fetched here, so it
  /// belongs to the capture `mic.start()` just brought up; see
  /// `MicCaptureProtocol.start()` for the race that shape rules out.
  ///
  /// The context is settled *here*, before the request opens, and that is the
  /// streaming route's doing: `config` leads the body, so there is no later
  /// moment to decide it in. The wait happens inside the upload task rather than
  /// on the actor — `beginContextCapture` dispatches the AX read off-actor
  /// precisely so a beachballing frontmost app cannot wedge `release()` or
  /// `cancel()`, and awaiting it on the actor here would hand that back.
  ///
  /// Nothing is published back afterwards: `capturedContext` reads the same
  /// `PressContext` this waits on, so the paste separator and the
  /// developer-mode log see the read whether or not the request gets anywhere —
  /// which is what `resolveCapturedContext` used to guarantee from the release
  /// side, and what a stored copy then needed a repair pass to keep true.
  func startUpload(frames: AsyncStream<Data>) {
    // Lifted out of the actor so the task body captures Sendable values rather
    // than isolated state, the same move `performPress` makes for `transcriber`.
    // `SyncSTTLimits.sampleRate` needs no such hoist — it is a static on an
    // enum, and neither does `contextWaitBudget`.
    let transcriber = transcriber
    let press = pressContext
    let clock = clock
    // Touches the actor nowhere: `PressContext` owns both the wait and the
    // value, so there is nothing to publish back and no `[weak self]`.
    upload = Task {
      let resolved = await press?.wait(within: Self.contextWaitBudget, clock: clock)
      // The request gets the read if it arrived and the press-known half if it
      // didn't, rather than nothing: key terms and the recent turns never needed
      // the AX round trip that just timed out. Only the *request* falls back —
      // `pressKnown` asserts a `targetIsSecure: false` it has no business
      // asserting, and `capturedContext`, which is where the release path reads
      // that flag, reads the resolved value and never this one.
      return try await transcriber.transcribe(
        frames: frames, sampleRate: SyncSTTLimits.sampleRate,
        context: resolved ?? press?.pressKnown)
    }
  }

  /// Abandons the in-flight dictation request — the streamed body can't be
  /// completed meaningfully once the audio behind it is going away, so the
  /// whole request goes rather than being left to finish on its own.
  /// Reached from `setPhase` for every terminal phase, so a dictation that ends
  /// without a transcript cannot leave a request streaming. The one explicit
  /// caller left is `stopAndCancel`, which has to run before `cancelCapture()`
  /// ends the feed.
  func cancelUpload() {
    upload?.cancel()
    upload = nil
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
    // cancel — the same trap `startUpload` avoids by taking `contextStream`
    // out of the actor's state in the turn it reads it, reached here because
    // this runs in a detached task that can outlive the press that started it.
    defer { if upload == inFlight { upload = nil } }
    do {
      return try await inFlight.value
    } catch {
      // A cancel() that landed mid-request already tore this task down and set
      // .cancelled; the transport then surfaces a cancellation-shaped error
      // (URLError(.cancelled) / CancellationError). Leave the claimed phase
      // alone rather than repainting the user's cancel as a red failure.
      if Task.isCancelled || error is CancellationError { return nil }
      // The producer refused to close a body below `SyncSTTLimits.minPCMBytes`.
      // `performRelease` normally catches that first and idles quietly; when the
      // producer gets there first instead, the outcome has to be the same
      // nothing rather than a red pill reading "too short to transcribe" — the
      // floor is one policy with two enforcement points, not two behaviours.
      if case AssemblyAIError.audioTooShort = error {
        setPhase(.idle)
        return nil
      }
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
