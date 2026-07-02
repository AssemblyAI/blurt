import AppKit
import os

public actor DictationSession {
  public private(set) var phase: PipelinePhase = .idle

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

  /// Live feed of phase changes for the single observer (the production app's
  /// AppCoordinator drives the overlay from it). Each `phaseStream()` call
  /// supersedes any prior one,
  /// yielding the current phase plus every subsequent transition. `currentID`
  /// tags the active continuation so a stream that's torn down after a newer one
  /// supersedes it doesn't clear the live continuation.
  private var continuation: AsyncStream<PipelinePhase>.Continuation?
  private var currentID = 0

  private let mic: MicCaptureProtocol
  private let transcriber: TranscriberProtocol
  private let injector: InjectorProtocol
  /// Supplies the user's key terms (domain vocabulary) at press time so each
  /// utterance's prompt primes those spellings. A closure, rather than a stored
  /// list, so edits in Settings take effect on the next dictation without
  /// rebuilding the session. Defaults to reading `KeyTermsStore`.
  private let keyTermsProvider: @Sendable () -> [String]
  /// Auto-releases the hotkey after this long so a held key can't run forever.
  /// Defaults to just under the AssemblyAI Sync STT audio cap (see
  /// `SyncSTTLimits`) — recording past it would only produce audio the sync
  /// endpoint rejects, so we stop early and transcribe what we have.
  private let maxRecordingSeconds: Double

  /// Sample rate the mic capture delivers and the Sync STT request declares —
  /// the Sync API's geometry, defined once in `SyncSTTLimits`.
  private static let captureSampleRate = SyncSTTLimits.sampleRate

  /// Context captured at `press()` (focused app + text before the cursor),
  /// passed to the transcriber so the Sync STT model has priming. Resolved from
  /// `contextTask` when the pipeline runs; stored so `inject`'s separator
  /// decision and the dictation log see the same snapshot.
  private var capturedContext: TranscriptionContext?

  /// The in-flight AX field-context read, started by `press()` — that's when the
  /// target field still holds focus — but awaited only in `runTranscribeInject`.
  /// Deliberately not awaited before `.recording`: the read is cross-process IPC
  /// into the frontmost app, and an unresponsive app must delay transcription
  /// (which needs the context), never the recording indicator (which doesn't).
  private var contextTask: Task<TranscriptionContext?, Never>?

  /// Tail of the serial command queue. `press()`/`release()`/`cancel()`/
  /// `cancelRecording()` chain behind it (see `enqueue`), so commands run one at
  /// a time in arrival order: no command ever observes another suspended
  /// mid-`mic.start()`/`mic.stop()`. This replaces the old `isStarting`/
  /// `isStopping` guards and pending-release/-cancel deferral flags outright.
  private var commandQueue: Task<Void, Never>?

  /// Set synchronously by `cancel()` before it takes its queue turn, so a cancel
  /// requested while a release is mid-`mic.stop()` deterministically wins:
  /// `performRelease` consumes the request after the stop, before any pipeline
  /// is spawned. `performCancel` clears it whether or not it was consumed early.
  private var cancelRequested = false

  /// Handle to the auto-release timer started in `press()`. Stored so that
  /// `release()` can cancel it — otherwise a fire-and-forget timer from a prior
  /// press could wake and `release()` a later, unrelated session.
  private var autoReleaseTask: Task<Void, Never>?

  /// Handle to the transcribe→inject work spawned by `release()`. Stored so a
  /// `cancel()` arriving after recording has stopped (phase `.transcribing` or
  /// `.injecting`) can tear it down — otherwise the transcript would still be
  /// pasted into the focused app despite the user cancelling. The cancellation it
  /// propagates is honored by `runTranscribeInject` and `KeyInjector.insert`.
  private var pipelineTask: Task<Void, Never>?

  public init(
    mic: MicCaptureProtocol,
    transcriber: TranscriberProtocol,
    injector: InjectorProtocol,
    maxRecordingSeconds: Double = SyncSTTLimits.autoReleaseSeconds,
    keyTermsProvider: @escaping @Sendable () -> [String] = { KeyTermsStore.terms() }
  ) {
    self.mic = mic
    self.transcriber = transcriber
    self.injector = injector
    self.maxRecordingSeconds = maxRecordingSeconds
    self.keyTermsProvider = keyTermsProvider
  }

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

  /// Appends `op` to the serial command queue and waits for it to run. The
  /// synchronous read-then-write of `commandQueue` makes the chain order match
  /// the order the public methods executed their first actor turn.
  private func enqueue(_ op: @escaping @Sendable () async -> Void) async {
    let previous = commandQueue
    let task = Task {
      await previous?.value
      await op()
    }
    commandQueue = task
    await task.value
  }

  public func press() async {
    await enqueue { await self.performPress() }
  }

  public func release() async {
    await enqueue { await self.performRelease() }
  }

  private func performPress() async {
    guard phase.isTerminal else { return }
    // Times the startup path — the concurrent focus capture + mic.start (and the
    // detached connection warm-up kicked off below) — up to the moment recording
    // actually begins. Ended on both the success and failure exits (mic.start is
    // the only throwing call, and it precedes `.recording`, so the two ends are
    // mutually exclusive).
    let pressInterval = Self.signposter.beginInterval(Self.pressSignpostName)
    do {
      // Pre-open the Sync connection while the user speaks, so the first dictation
      // after an idle gap doesn't pay DNS+TCP+TLS on the transcribe hot path
      // (~170 ms cold, measured). Detached + fire-and-forget: it must never delay
      // recording, and a failure is harmless (the request just pays setup as
      // before). Warming every press is cheap — when the pool is already hot the
      // throwaway request reuses it rather than handshaking again.
      let transcriber = transcriber
      Task.detached { await transcriber.warmUp() }
      // Capture the frontmost app (paste target) concurrently with mic startup —
      // a cheap in-process AppKit read on the main actor. The phase still flips
      // to .recording only after mic.start succeeds, so the UI never lies about
      // whether audio is being captured.
      async let frontmost = MainActor.run { FocusCapture.captureFrontmost() }
      try await mic.start()
      let captured = await frontmost
      await injector.setTargetApp(captured.flatMap { FocusCapture.runningApp(for: $0) })
      // Key terms are read synchronously at press (cheap UserDefaults read), so
      // each dictation observably re-reads Settings edits at press time.
      let keyTerms = keyTermsProvider()
      // Kick off the AX field-context read now, while the target field still
      // holds focus, but don't await it here: it's cross-process IPC into the
      // frontmost app (detached — off the main actor, where it froze the
      // overlay, and off this actor, where it would wedge release()/cancel()),
      // and runTranscribeInject awaits it right before transcription. A slow AX
      // target therefore delays the transcript, never the recording indicator.
      contextTask = Task.detached {
        let field = FocusCapture.captureFieldContext()
        let context = TranscriptionContext(
          appName: captured?.processName,
          windowTitle: field.windowTitle,
          fieldLabel: field.fieldLabel,
          priorText: field.priorText,
          selectedText: field.selectedText,
          keyTerms: keyTerms)
        return context.isEmpty ? nil : context
      }
      setPhase(.recording)
      Self.signposter.endInterval(Self.pressSignpostName, pressInterval)
      let timeout = maxRecordingSeconds
      autoReleaseTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(timeout))
        guard let self, !Task.isCancelled else { return }
        // Enqueues like a manual key-up. If a real release already ran, the
        // queued performRelease sees a non-.recording phase and drops out.
        await self.release()
      }
    } catch {
      Self.signposter.endInterval(Self.pressSignpostName, pressInterval)
      setPhase(.failed(.audioCaptureFailed(underlying: error)))
    }
  }

  private func performRelease() async {
    guard phase == .recording else { return }
    cancelAutoRelease()
    let samples: [Float]
    do {
      samples = try await mic.stop()
    } catch {
      // A cancel requested while mic.stop() was in flight wins over surfacing
      // the audio error — the user asked for nothing to happen.
      if consumeCancelRequest() { return }
      // Audio capture/conversion failed (e.g. sample-rate conversion couldn't
      // run). Surface it instead of silently transcribing an empty buffer.
      setPhase(.failed(.audioCaptureFailed(underlying: error)))
      return
    }
    // A cancel() requested while mic.stop() was in flight is honored here,
    // before any pipeline exists — deterministically no transcription, no paste.
    if consumeCancelRequest() { return }
    setPhase(.transcribing)
    pipelineTask = Task { [weak self] in
      await self?.runTranscribeInject(samples: samples)
    }
  }

  /// Consumes a cancel requested while this release held the queue, claiming the
  /// phase for the user's cancel. Returns whether it fired.
  private func consumeCancelRequest() -> Bool {
    guard cancelRequested else { return false }
    cancelRequested = false
    setPhase(.cancelled)
    return true
  }

  public func cancel() async {
    // A cancel that lands after recording has already stopped — while the
    // transcribe→inject task is in flight — tears that task down so the
    // transcript is never injected, and claims the phase so the cancelled
    // pipeline can't overwrite it back to .idle. Synchronous (no suspension), so
    // it acts immediately rather than queueing behind the pipeline's progress.
    if phase == .transcribing || phase == .injecting {
      pipelineTask?.cancel()
      pipelineTask = nil
      setPhase(.cancelled)
      return
    }
    // Record the intent before taking a queue turn: a release currently mid-
    // `mic.stop()` consumes it the moment the stop returns (no pipeline is ever
    // spawned), and a press ahead in the queue is followed by our own turn,
    // which ends the freshly started recording. Either way the cancel is
    // honored in arrival order, never dropped.
    cancelRequested = true
    await enqueue { await self.performCancel() }
  }

  private func performCancel() async {
    // Our turn is the cancel — clear the request whether or not an earlier
    // release already consumed it.
    cancelRequested = false
    guard phase == .recording else { return }
    await stopAndCancel()
  }

  /// Cancels only a live *recording* — the narrow cancel for synthetic,
  /// state-recovery callers (the event tap's disabled-tap recovery and trigger
  /// rebinding), whose intent is "the key events ending this capture may be
  /// lost". Unlike `cancel()`, it never tears down a `.transcribing`/`.injecting`
  /// pipeline and never preempts a queued release: reaching this op's turn with
  /// the capture already ended (or ending) means a release happened
  /// legitimately (e.g. the auto-release cap fired while the gate was still
  /// latched), and discarding that transcript would lose the user's words.
  public func cancelRecording() async {
    await enqueue { await self.performCancelRecording() }
  }

  private func performCancelRecording() async {
    guard phase == .recording else { return }
    await stopAndCancel()
  }

  /// Shared tail of the cancel ops once the guards agree there is a live
  /// recording to tear down.
  private func stopAndCancel() async {
    cancelAutoRelease()
    _ = try? await mic.stop()
    setPhase(.cancelled)
  }

  private func cancelAutoRelease() {
    autoReleaseTask?.cancel()
    autoReleaseTask = nil
  }

  private func runTranscribeInject(samples: [Float]) async {
    // Times the full post-release hot path — Sync STT round trip plus the paste
    // (including the clipboard settle) — across every exit (short-clip no-op,
    // empty transcript, failure, cancel, or a completed paste).
    let pipelineInterval = Self.signposter.beginInterval(Self.pipelineSignpostName)
    defer { Self.signposter.endInterval(Self.pipelineSignpostName, pipelineInterval) }
    // A clip too short for the Sync model (an accidental brief tap) would only
    // earn a 400 — drop it as a silent no-op, like an empty transcript, rather
    // than calling the API and surfacing an error.
    guard samples.count >= SyncSTTLimits.minSamples else {
      // A cancel() racing the freshly spawned pipeline task already claimed the
      // phase — don't overwrite .cancelled with .idle.
      if !Task.isCancelled { setPhase(.idle) }
      return
    }

    // Resolve the press-time AX field read now that it's actually needed. In the
    // common case it finished long ago (the user spoke for a while); against an
    // unresponsive app it's bounded by the AX messaging timeout.
    capturedContext = await contextTask?.value
    contextTask = nil

    // The Sync STT API applies the cleanup prompt server-side, so the transcript
    // it returns is already the final, polished text — there is no separate
    // styling pass.
    guard let text = await transcribe(samples: samples) else { return }

    // A cancel() that landed while transcribe was in flight already set
    // .cancelled and detached this task — don't inject or touch the phase.
    if Task.isCancelled { return }

    if text.trimmedNonEmpty() == nil {
      setPhase(.idle)
      return
    }

    DictationLog.append(raw: text, polished: text, context: capturedContext)
    await inject(text)
  }

  /// Runs the single Sync STT request. Returns the transcript, or nil if it
  /// failed (phase set to `.failed`).
  private func transcribe(samples: [Float]) async -> String? {
    do {
      return try await transcriber.transcribe(
        samples: samples, sampleRate: Self.captureSampleRate, context: capturedContext)
    } catch {
      // A cancel() that landed mid-request already tore this task down and set
      // .cancelled; the transport then surfaces a cancellation-shaped error
      // (URLError(.cancelled) / CancellationError). Leave the claimed phase
      // alone rather than repainting the user's cancel as a red failure.
      if Task.isCancelled || error is CancellationError { return nil }
      if let err = error as? BlurtError {
        // e.g. `.apiKeyMissing` — surface it directly rather than burying it
        // inside `.sttFailed`.
        setPhase(.failed(err))
      } else {
        setPhase(.failed(.sttFailed(underlying: error)))
      }
      return nil
    }
  }

  private func inject(_ text: String) async {
    setPhase(.injecting)
    do {
      try await injector.insert(text, after: capturedContext?.priorText)
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
      switch error {
      case BlurtError.noEditableTarget, BlurtError.targetAppLost:
        // Not failures: transcription worked, the words just couldn't be pasted
        // — nothing editable was focused, or the target app quit/refused
        // activation. Either way the injector left the text on the clipboard —
        // show the quiet "copied" notice rather than the red error flash (and
        // don't report it).
        setPhase(.noTarget)
      case let err as BlurtError:
        // Surface the injector's real error (e.g. `.accessibilityPermissionMissing`)
        // rather than relabeling every failure as a lost target.
        setPhase(.failed(err))
      default:
        // An untyped injection error: nothing was left on the clipboard, so this
        // stays a genuine (reported) failure under the generic lost-target label.
        setPhase(.failed(.targetAppLost))
      }
    }
  }

  private func setPhase(_ newPhase: PipelinePhase) {
    phase = newPhase
    continuation?.yield(newPhase)
  }
}
