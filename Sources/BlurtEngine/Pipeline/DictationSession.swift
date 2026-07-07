import Foundation
import os

public actor DictationSession {
  public private(set) var phase: PipelinePhase = .idle

  // Split for the lint file-length budget: `phaseStream()`/os_signpost live in
  // `+Observation`; `submit(_:)` lives in `+Commands`; the post-release
  // transcribe→inject pipeline lives in `+Pipeline`. Members those files reach
  // are internal, not private (file-scoped access can't cross the split).

  /// Live feeds of phase changes. Each `phaseStream()` call yields the current
  /// phase plus every subsequent transition, so the production renderer and
  /// auxiliary/debug views can observe the same session without disconnecting
  /// each other.
  var continuations: [Int: AsyncStream<PipelinePhase>.Continuation] = [:]
  var currentID = 0

  /// Feed behind the nonisolated `submit(_:)` (see `+Commands`): commands are
  /// yielded synchronously — preserving the caller's emit order — and consumed
  /// one at a time by the task spawned in `init`.
  nonisolated let commandFeed: AsyncStream<Command>.Continuation

  private let mic: MicCaptureProtocol
  let transcriber: TranscriberProtocol
  let injector: InjectorProtocol
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
  /// Clock the auto-release timer and the context-wait budget (`+Pipeline`)
  /// sleep on; injectable so tests advance it.
  let clock: any Clock<Duration>

  /// Consulted at the top of `press()`: a non-nil blocker refuses the press
  /// before any capture begins, surfacing as `.failed(blocker)`. Keeps "never
  /// record audio you can't transcribe" an engine invariant — the app passes a
  /// key-presence check so a missing API key fails at press time, not after the
  /// user has spoken a whole utterance. Defaults to always-ready (no Keychain
  /// read), so tests and keyless hosts are unaffected unless they opt in.
  private let readinessCheck: @Sendable () -> BlurtError?
  /// Fired once with the final transcript as soon as it's produced — before
  /// injection, so pasted, copied, and failed-to-paste dictations all count.
  let onTranscriptDelivered: (@Sendable (String) -> Void)?

  /// Context captured at `press()` (focused app + prior text), stored so the
  /// transcriber, `inject`'s separator decision, and the log share one snapshot.
  var capturedContext: TranscriptionContext?

  /// The in-flight AX field-context read, started by `press()` — that's when
  /// the target field still holds focus — but consumed only in
  /// `runTranscribeInject`, bounded by `contextWaitBudget`. Deliberately not
  /// awaited before `.recording`: the read is cross-process IPC into the
  /// frontmost app, and an unresponsive app must never delay the recording
  /// indicator. A buffered stream rather than a `Task` so the bounded wait can
  /// abandon a hung read (awaiting a `Task.value` is not cancellable).
  var contextStream: AsyncStream<TranscriptionContext?>?

  /// Tail of the serial command queue. `press()`/`release()`/`cancel()`/
  /// `cancelRecording()` chain behind it (see `enqueue`), so commands run one at
  /// a time in arrival order — none observes another suspended mid-`mic` call.
  private var commandQueue: Task<Void, Never>?

  /// Set synchronously by `cancel()` before it takes its queue turn, so a
  /// cancel arriving while a queued release hasn't yet claimed `.transcribing`
  /// deterministically wins: `performRelease` consumes the request after its
  /// `mic.stop()`, before any pipeline is spawned. (A release that already
  /// claimed `.transcribing` is handled by `cancel()`'s synchronous path
  /// instead.) `performCancel` clears it whether or not it was consumed early.
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
  var pipelineTask: Task<Void, Never>?  // internal: joined by awaitPipeline()

  public init(
    mic: MicCaptureProtocol,
    transcriber: TranscriberProtocol,
    injector: InjectorProtocol,
    maxRecordingSeconds: Double = SyncSTTLimits.autoReleaseSeconds,
    clock: any Clock<Duration> = ContinuousClock(),
    keyTermsProvider: @escaping @Sendable () -> [String] = { KeyTermsStore.terms() },
    readinessCheck: @escaping @Sendable () -> BlurtError? = { nil },
    onTranscriptDelivered: (@Sendable (String) -> Void)? = nil
  ) {
    self.mic = mic
    self.transcriber = transcriber
    self.injector = injector
    self.maxRecordingSeconds = maxRecordingSeconds
    self.clock = clock
    self.keyTermsProvider = keyTermsProvider
    self.readinessCheck = readinessCheck
    self.onTranscriptDelivered = onTranscriptDelivered
    let (commands, feed) = AsyncStream.makeStream(of: Command.self)
    self.commandFeed = feed
    // Consumes `submit(_:)`'s feed one command at a time, in emit order. Weakly
    // held so the consumer never keeps the session alive; `deinit` finishes the
    // feed so the loop (and its task) winds down with the session.
    Task { [weak self] in
      for await command in commands {
        guard let self else { return }
        await self.run(command)
      }
    }
  }

  deinit {
    commandFeed.finish()
    for continuation in continuations.values {
      continuation.finish()
    }
  }

  /// Appends `op` to the serial command queue and waits for it to run. The
  /// synchronous read-then-write of `commandQueue` makes the chain order match
  /// the order the public methods executed their first actor turn.
  func enqueue(_ op: @escaping @Sendable () async -> Void) async {
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
    // Refuse the press before any capture begins when the host reports a
    // blocker (e.g. no API key saved): recording an utterance that can only
    // fail at transcribe time would discard the user's words after the fact.
    if let blocker = readinessCheck() {
      setPhase(.failed(blocker))
      return
    }
    // Times the startup path — the concurrent focus capture + mic.start (and the
    // detached connection warm-up kicked off below) — up to the moment recording
    // actually begins. Ended on both the success and failure exits (mic.start is
    // the only throwing call, and it precedes `.recording`, so the two ends are
    // mutually exclusive).
    let pressInterval = Self.signposter.beginInterval(Self.pressSignpostName)
    do {
      // Pre-open the Sync connection while the user speaks, so the first dictation after an idle
      // gap doesn't pay DNS+TCP+TLS on the transcribe hot path (~170 ms cold, measured). Detached
      // + fire-and-forget: it must never delay recording, and a failure is harmless (the request
      // just pays setup as before); warming every press is cheap since a hot pool just reuses it.
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
      // overlay, and off this actor, where it would wedge release()/cancel()).
      // runTranscribeInject consumes the result right before transcription,
      // bounded by `contextWaitBudget` — so a slow AX target delays the
      // transcript by at most the budget, never the recording indicator.
      let (stream, contextFeed) = AsyncStream.makeStream(
        of: TranscriptionContext?.self, bufferingPolicy: .bufferingNewest(1))
      contextStream = stream
      Task.detached {
        let field = FocusCapture.captureFieldContext()
        let context = TranscriptionContext(
          appName: captured?.processName,
          windowTitle: field.windowTitle,
          fieldLabel: field.fieldLabel,
          priorText: field.priorText,
          selectedText: field.selectedText,
          keyTerms: keyTerms)
        contextFeed.yield(context.isEmpty ? nil : context)
        contextFeed.finish()
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
      setPhase(.failed(.audioCaptureFailed(underlying: error)))
    }
  }

  private func performRelease() async {
    guard phase == .recording else { return }
    cancelAutoRelease()
    // Flip the phase before stopping the mic, not after: the stop chime and
    // the pill's "Transcribing…" ride this transition, and mic.stop() reads
    // the whole recording back from disk — I/O the user's "it heard me" cue
    // must not wait on. This also closes the double-release window: a second
    // release arriving during the mic.stop() suspension now fails the
    // `.recording` guard above instead of running the pipeline twice.
    setPhase(.transcribing)
    let pcm: Data
    do {
      pcm = try await mic.stop()
    } catch {
      // A cancel that landed while mic.stop() was in flight wins over
      // surfacing the audio error — the user asked for nothing to happen. It
      // arrived either synchronously (cancel() saw `.transcribing` and claimed
      // the phase, moving it off `.transcribing`) or as a recorded request
      // from before this release's turn, consumed here.
      if consumeCancelRequest() || phase != .transcribing { return }
      // Audio capture/conversion failed (e.g. the recorded file couldn't be
      // read back). Surface it instead of silently transcribing an empty blob.
      setPhase(.failed(.audioCaptureFailed(underlying: error)))
      return
    }
    // The same two cancel paths, honored here before any pipeline exists —
    // deterministically no transcription, no paste.
    if consumeCancelRequest() || phase != .transcribing { return }
    pipelineTask = Task { [weak self] in
      await self?.runTranscribeInject(pcm: pcm)
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
    // A cancel that lands once `.transcribing` is claimed — while the release
    // is still inside mic.stop(), or later with the transcribe→inject task in
    // flight — tears the pipeline down (a nil or finished handle is a no-op)
    // and claims the phase, so neither the release (which re-checks the phase
    // after mic.stop()) nor the cancelled pipeline can overwrite it back to
    // .idle. Synchronous (no suspension), so it acts immediately rather than
    // queueing behind the pipeline's progress.
    if phase == .transcribing || phase == .injecting {
      // Cancel but keep the handle so `awaitPipeline()` can join the cancelled task.
      pipelineTask?.cancel()
      setPhase(.cancelled)
      return
    }
    // Record the intent before taking a queue turn: a release queued ahead of
    // our turn consumes it the moment its mic.stop() returns (no pipeline is
    // ever spawned), and a press ahead in the queue is followed by our own
    // turn, which ends the freshly started recording. Either way the cancel is
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

  // `cancelRecording()` — the narrow, state-recovery cancel — lives with the
  // rest of the command surface in `DictationSession+Commands.swift`.

  /// Shared tail of the cancel ops once the guards agree there is a live
  /// recording to tear down.
  func stopAndCancel() async {
    cancelAutoRelease()
    _ = try? await mic.stop()
    setPhase(.cancelled)
  }

  private func cancelAutoRelease() {
    autoReleaseTask?.cancel()
    autoReleaseTask = nil
  }

  // The post-release pipeline — `runTranscribeInject` and its transcribe/inject
  // halves, plus the bounded context wait — lives in
  // `DictationSession+Pipeline.swift` (see the split note at the top).

  func setPhase(_ newPhase: PipelinePhase) {
    phase = newPhase
    for continuation in continuations.values {
      continuation.yield(newPhase)
    }
  }
}
