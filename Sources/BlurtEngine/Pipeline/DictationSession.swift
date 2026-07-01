import AppKit
import os

public actor DictationSession {
  public private(set) var phase: PipelinePhase = .idle

  /// Signposter for the latency-sensitive segments of a dictation. Emitted as
  /// os_signpost intervals so Instruments can time them live and, more
  /// importantly, so `XCTOSSignpostMetric` can assert them in the performance
  /// suite — a regression guard on the hand-tuned hot paths (mic/connection
  /// warm-up on press, the transcribe→paste round trip on release). The subsystem
  /// and category are matched verbatim by `DictationPerformanceTests`.
  static let signposter = OSSignposter(subsystem: "dev.alex.blurt", category: "DictationPipeline")
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

  /// Sample rate the mic capture delivers and the Sync STT request declares.
  private static let captureSampleRate = 16_000

  /// Context captured at `press()` (focused app + text before the cursor),
  /// passed to the transcriber so the Sync STT model has priming. Captured at
  /// press time because that's when the target field still holds focus.
  private var capturedContext: TranscriptionContext?

  /// Guards `press()` across its `await mic.start()` suspension. Actors are
  /// reentrant, so the `phase.isTerminal` check alone can't stop a second
  /// `press()` arriving mid-`start()` (`.recording` isn't set until start
  /// returns) from starting the mic twice.
  private var isStarting = false

  /// Guards `release()` across its `await mic.stop()` suspension. `release()` has
  /// two triggers (manual key-up and the auto-release timer); without this, a
  /// second release arriving during `mic.stop()` would re-pass the
  /// `phase == .recording` guard (phase isn't `.transcribing` until stop returns)
  /// and run the pipeline a second time — double-stopping the mic and injecting
  /// the transcript twice.
  private var isStopping = false

  /// Set when `release()` arrives while `press()` is still inside `mic.start()` —
  /// i.e. before `phase` flips to `.recording`. `press()` consumes it the moment
  /// recording begins, so a fast tap can't strand the session in `.recording` by
  /// having its release silently dropped.
  private var pendingRelease = false

  /// Set when `cancel()` arrives while `press()` is still inside `mic.start()`.
  /// `press()` consumes it the moment recording begins, so a fast cancel can't
  /// strand the session in `.recording` by having its cancel silently dropped.
  private var pendingCancel = false

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

  public func press() async {
    guard phase.isTerminal, !isStarting else { return }
    isStarting = true
    pendingRelease = false
    pendingCancel = false
    defer { isStarting = false }
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
      // Capture the focused app + prior text concurrently with mic startup. The
      // phase still flips to .recording only after mic.start succeeds, so the UI
      // never lies about whether audio is being captured.
      async let captured = captureFocus()
      try await mic.start()
      let focus = await captured
      await injector.setTargetApp(focus.app)
      capturedContext = focus.context
      setPhase(.recording)
      Self.signposter.endInterval(Self.pressSignpostName, pressInterval)
      let timeout = maxRecordingSeconds
      autoReleaseTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(timeout))
        guard let self, !Task.isCancelled else { return }
        await self.releaseIfRecording()
      }
      // A release or cancel that raced in while mic.start() was still in flight was
      // deferred (phase wasn't .recording yet) — honor it now so the press doesn't
      // strand the session in .recording.
      if pendingCancel {
        pendingCancel = false
        await cancel()
      } else if pendingRelease {
        pendingRelease = false
        await release()
      }
    } catch {
      Self.signposter.endInterval(Self.pressSignpostName, pressInterval)
      setPhase(.failed(.audioCaptureFailed(underlying: error)))
    }
  }

  public func release() async {
    guard phase == .recording, !isStopping else {
      // press() hasn't reached .recording yet (still inside mic.start()). Defer
      // the release so press() honors it once recording begins, rather than
      // dropping it — see `pendingRelease`. (A release that races in while an
      // earlier one is already stopping is simply dropped.)
      if isStarting { pendingRelease = true }
      return
    }
    isStopping = true
    defer { isStopping = false }
    cancelAutoRelease()
    let samples: [Float]
    do {
      samples = try await mic.stop()
    } catch {
      // Audio capture/conversion failed (e.g. sample-rate conversion couldn't
      // run). Surface it instead of silently transcribing an empty buffer.
      setPhase(.failed(.audioCaptureFailed(underlying: error)))
      return
    }
    setPhase(.transcribing)
    pipelineTask = Task { [weak self] in
      await self?.runTranscribeInject(samples: samples)
    }
  }

  public func cancel() async {
    // A cancel that lands after recording has already stopped — while the
    // transcribe→inject task is in flight — tears that task down so the
    // transcript is never injected, and claims the phase so the cancelled
    // pipeline can't overwrite it back to .idle.
    if phase == .transcribing || phase == .injecting {
      pipelineTask?.cancel()
      pipelineTask = nil
      setPhase(.cancelled)
      return
    }
    guard phase == .recording, !isStopping else {
      // press() hasn't reached .recording yet (still inside mic.start()). Defer
      // the cancel so press() honors it once recording begins, rather than
      // dropping it — see `pendingCancel`. (A cancel that races in while an
      // earlier release or cancel is already stopping is simply dropped, and
      // cancel overrides release).
      if isStarting {
        pendingCancel = true
        pendingRelease = false
      }
      return
    }
    isStopping = true
    defer { isStopping = false }
    cancelAutoRelease()
    _ = try? await mic.stop()
    setPhase(.cancelled)
  }

  /// Body of the auto-release timer: only release if we're still recording the
  /// same session that armed the timer (the timer is cancelled on an earlier
  /// release, so reaching here means this session is genuinely overrun).
  private func releaseIfRecording() async {
    guard phase == .recording else { return }
    await release()
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
    guard samples.count >= SyncSTTLimits.minSamples(sampleRate: Self.captureSampleRate) else {
      setPhase(.idle)
      return
    }

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
    } catch let err as BlurtError {
      // e.g. `.apiKeyMissing` — surface it directly rather than burying it
      // inside `.sttFailed`.
      setPhase(.failed(err))
      return nil
    } catch {
      setPhase(.failed(.sttFailed(underlying: error)))
      return nil
    }
  }

  private func inject(_ text: String) async {
    setPhase(.injecting)
    do {
      try await injector.insert(text, after: capturedContext?.priorText)
      // The paste landed — show the quiet "pasted" notice (the mirror of the
      // "copied" notice below) rather than snapping straight back to idle.
      setPhase(.pasted)
    } catch is CancellationError {
      // A cancel() landed mid-paste: it already set .cancelled and the injector
      // bailed before typing. Leave the phase alone rather than relabeling this
      // as a failure.
      return
    } catch BlurtError.noEditableTarget {
      // Not a failure: transcription worked, there was just nowhere to type. The
      // injector left the text on the clipboard — show the quiet "copied" notice
      // rather than the red error flash (and don't page Sentry).
      setPhase(.noTarget)
    } catch let err as BlurtError {
      // Surface the injector's real error (e.g. `.targetAppLost`) rather than
      // relabeling every failure as a lost target.
      setPhase(.failed(err))
    } catch {
      setPhase(.failed(.targetAppLost))
    }
  }

  /// The frontmost app (for paste targeting) plus the STT priming context,
  /// gathered together in a single MainActor hop at press time.
  private struct FocusSnapshot: Sendable {
    let app: NSRunningApplication?
    let context: TranscriptionContext?
  }

  private func captureFocus() async -> FocusSnapshot {
    let (captured, field) = await MainActor.run {
      () -> (CapturedFocus?, FocusCapture.FocusedFieldContext) in
      (FocusCapture.captureFrontmost(), FocusCapture.captureFieldContext())
    }
    let app = captured.flatMap { FocusCapture.runningApp(for: $0) }
    let context = TranscriptionContext(
      appName: captured?.processName,
      windowTitle: field.windowTitle,
      fieldLabel: field.fieldLabel,
      priorText: field.priorText,
      selectedText: field.selectedText,
      keyTerms: keyTermsProvider())
    return FocusSnapshot(app: app, context: context.isEmpty ? nil : context)
  }

  private func setPhase(_ newPhase: PipelinePhase) {
    phase = newPhase
    continuation?.yield(newPhase)
  }
}
