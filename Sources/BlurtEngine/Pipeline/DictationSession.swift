// `Dispatch`, not `Foundation`: the only thing here from outside the module is
// `contextQueue`'s and `commandQueue`'s `DispatchQueue`, the same choice
// `+Press.swift` documents. Foundation's last use here went with `mic.stop()`
// returning a byte count instead of a `Data` blob.
import Dispatch
import Synchronization

public actor DictationSession {
  /// Off-pool home for the press-time AX field read — see its use in
  /// `performPress` for why blocking IPC must not run on the cooperative pool.
  static let contextQueue = DispatchQueue(
    label: HostIdentity.current.queueLabel("FieldContext"), qos: .userInitiated,
    attributes: .concurrent)

  /// `internal(set)`, not `private(set)`: `private` is file-scoped, and the one
  /// writer — `setPhase` — lives in `+Observation` (see the split note below).
  /// Hosts outside the module still can't assign it. **`setPhase` remains the
  /// only place this is written**: it is what publishes the transition to every
  /// `phaseStream()` observer and what writes the developer-mode error log, so a
  /// bare `phase = …` anywhere else would strand the UI on a stale phase and drop
  /// the failure from the log.
  public internal(set) var phase: PipelinePhase = .idle

  // Split for the lint file-length budget: `performPress` — the whole press half,
  // including the mic bring-up — lives in `+Press`, mirroring the post-release
  // transcribe→inject pipeline in `+Pipeline`. `submit(_:)`, both cancel commands
  // and the cancel-intent accessors over `cancelState` live in `+Commands`;
  // `phaseStream()`/`setPhase`/os_signpost live in `+Observation`; the
  // non-protocol collaborators (focus capture, developer-mode log) live in
  // `+Seams`. Members those files reach are internal, not private (file-scoped
  // access can't cross the split) — including `phase`'s setter.

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

  let mic: MicCaptureProtocol
  let transcriber: TranscriberProtocol
  let injector: InjectorProtocol
  /// Supplies the user's key terms (domain vocabulary) at press time, so each
  /// utterance's request boosts those spellings — as its own `keyterms_prompt` field
  /// (`KeytermsBoost`), not as part of the conversation context. A closure, rather
  /// than a stored list, so edits in Settings take effect on the next dictation
  /// without rebuilding the session. Defaults to reading `KeyTermsStore`.
  let keyTermsProvider: @Sendable () -> [String]
  /// Names the style a completed dictation was made with, recorded onto its
  /// `RecentDictations.Entry` (the row's trailing style chip). `nil` means no
  /// *custom* style shaped it — enhanced transcripts off, or the base Cleaned
  /// Up styling with no profile active — and the entry shows only its
  /// timestamp: the base treatment is every row's default, so naming it on
  /// each would be noise. A closure for the same live-read reason as
  /// `keyTermsProvider`; the default reads the stores.
  let styleNameProvider: @Sendable () -> String?
  /// The text shortcuts expanded into each transcript before the paste; live-read.
  let textShortcutsProvider: @Sendable () -> [TextShortcut]
  /// Auto-releases the hotkey after this long so a held key can't run forever.
  /// Defaults to just under the dictation API's audio cap (see
  /// `SyncSTTLimits`) — recording past it would only produce audio the
  /// endpoint rejects, so we stop early and transcribe what we have.
  let maxRecordingSeconds: Double
  /// Clock the auto-release timer and the context-wait budget (`+Pipeline`)
  /// sleep on; injectable so tests advance it.
  let clock: any Clock<Duration>

  /// Consulted at the top of `press()`: a non-nil blocker refuses the press
  /// before any capture begins, surfacing as `.failed(blocker)`. Keeps "never
  /// record audio you can't transcribe" an engine invariant — the app passes a
  /// key-presence check so a missing API key fails at press time, not after the
  /// user has spoken a whole utterance. Defaults to always-ready (no Keychain
  /// read), so tests and keyless hosts are unaffected unless they opt in.
  let readinessCheck: @Sendable () -> BlurtError?
  /// Fired once with the final transcript as soon as it's produced — before
  /// injection, so pasted, copied, and failed-to-paste dictations all count. The
  /// second argument is `recentDictations` as it stands, pushed from its one owner
  /// so the "Recent" list is a projection rather than a second ring (see it).
  let onTranscriptDelivered: (@Sendable (String, RecentDictations) -> Void)?

  /// The focus capture and the developer-mode log, behind closures rather than
  /// called as statics — see `Seams` in `DictationSession+Seams.swift` for why.
  /// Internal so `+Pipeline` reaches it across the file split.
  let seams: Seams

  /// The press-time capture, for `inject`'s separator decision and the log.
  ///
  /// Derived, not stored: `PressContext` already holds exactly one read per
  /// press, so a stored copy could only ever be a cache of it — and was, until
  /// the release path had to repair it whenever `startUpload`'s deadline had
  /// elapsed before the read landed. Reading through means every reader gets the
  /// freshest known value wherever it runs, instead of the value as of the
  /// moment the upload opened. The request itself may hold something different
  /// (`PressContext.pressKnown`, when the budget was missed), which is
  /// deliberate — see `startUpload`.
  var capturedContext: TranscriptionContext? { pressContext?.resolved }

  /// The user's recent dictations, in memory for this launch only — and the **one**
  /// copy of that history. Recorded in `runTranscribeInject` (`+Pipeline`) just
  /// before `onTranscriptDelivered` fires, and read at press time into
  /// `TranscriptionContext.recentTranscripts`, which sends them as the leading
  /// leading `stt_prompt` lines — so a run of dictations reads to the model as
  /// one continuing dialogue rather than N unrelated clips.
  ///
  /// It lives here, not in the host, because the request is assembled inside this
  /// actor: a ring held as MainActor UI state couldn't be read at press time
  /// without a hop. The "Recent" list is pushed the updated value instead. Internal
  /// so `+Pipeline` reaches it across the file split.
  var recentDictations = RecentDictations()

  /// The AX field-context read started by `press()` — that's when the target
  /// field still holds focus — and the two ways it is read: `wait` when
  /// `startUpload` opens the request, a peek at release. Deliberately not
  /// awaited before `.recording`, because the read is cross-process IPC into the
  /// frontmost app and an unresponsive app must never delay the recording
  /// indicator. See `PressContext` for why one value needs two deadlines.
  var pressContext: PressContext?

  /// Tail of the serial command queue. `press()`/`release()`/`cancel()`/
  /// `cancelRecording()` chain behind it (see `enqueue`), so commands run one at
  /// a time in arrival order — none observes another suspended mid-`mic` call.
  private var commandQueue: Task<Void, Never>?

  /// Backing store for `cancelRequested` and `inFlightPress`. A `Mutex` rather
  /// than actor state because **both doors into a cancel must record it
  /// synchronously**, and one of them is `nonisolated`: `submit(.cancel)` can't
  /// take an actor turn, and waiting for one is exactly the bug — the command
  /// consumer is serial, so a submitted cancel sits unread in the feed until the
  /// press it means to cancel has finished.
  let cancelState = Mutex(CancelState())

  struct CancelState {
    var requested = false
    var press: Task<Void, Never>?
  }

  // Internal, like `pipelineTask`, so a test can witness the cancel teardown
  // *directly* — nil means disarmed. Asserting it through the timer's effects
  // doesn't work: a surviving timer wakes, calls `release()`, and `performRelease`
  // drops out on `guard phase == .recording`, so a cancelled session looks
  // identical either way and the test passes with `cancelAutoRelease()` deleted.
  /// Handle to the auto-release timer started in `press()`. Stored so that
  /// `release()` can cancel it — otherwise a fire-and-forget timer from a prior
  /// press could wake and `release()` a later, unrelated session.
  var autoReleaseTask: Task<Void, Never>?

  /// Handle to the transcribe→inject work spawned by `release()`. Stored so a
  /// `cancel()` arriving after recording has stopped (phase `.transcribing` or
  /// `.injecting`) can tear it down — otherwise the transcript would still be
  /// pasted into the focused app despite the user cancelling. The cancellation it
  /// propagates is honored by `runTranscribeInject` and `KeyInjector.insert`.
  var pipelineTask: Task<Void, Never>?  // internal: joined by awaitPipeline()

  /// The in-flight dictation request, opened at press so the recording uploads
  /// while the user speaks. Stored for the same reason `pipelineTask` is: it is
  /// unstructured work a cancel has to be able to reach, and cancelling
  /// `pipelineTask` alone would abandon only the *wait* — the request itself
  /// would keep streaming and complete against a dictation the user dismissed.
  ///
  /// A bare task, because that is now all a live request is. It was an
  /// `InFlightUpload` pairing the task with the context channel its `config`
  /// part parked on, so abandoning it meant closing that too; the streaming
  /// route settles the context up front, so `cancel()` is now the whole of it.
  var upload: Task<String, any Error>?

  /// The production entry point: the real focus capture and the real
  /// developer-mode log. Delegates to the seam-carrying initializer below, which
  /// can't be public because it names internal types.
  public init(
    mic: MicCaptureProtocol,
    transcriber: TranscriberProtocol,
    injector: InjectorProtocol,
    maxRecordingSeconds: Double = SyncSTTLimits.autoReleaseSeconds,
    clock: any Clock<Duration> = ContinuousClock(),
    keyTermsProvider: (@Sendable () -> [String])? = nil,
    styleNameProvider: (@Sendable () -> String?)? = nil,
    textShortcutsProvider: (@Sendable () -> [TextShortcut])? = nil,
    readinessCheck: @escaping @Sendable () -> BlurtError? = { nil },
    onTranscriptDelivered: (@Sendable (String, RecentDictations) -> Void)? = nil
  ) {
    self.init(
      mic: mic, transcriber: transcriber, injector: injector,
      maxRecordingSeconds: maxRecordingSeconds, clock: clock,
      keyTermsProvider: keyTermsProvider, styleNameProvider: styleNameProvider,
      textShortcutsProvider: textShortcutsProvider, readinessCheck: readinessCheck,
      onTranscriptDelivered: onTranscriptDelivered, seams: .production)
  }

  /// `seams` is deliberately required rather than defaulted: it's what keeps this
  /// initializer distinct from the public one above, so an in-module call is never
  /// ambiguous. `keyTermsProvider` is optional-and-resolved-here rather than
  /// defaulted in the signature for the same reason `AssemblyAITranscriber`'s
  /// `enhancedTranscripts` is — a public default argument can't reference the
  /// store's internal members.
  init(
    mic: MicCaptureProtocol,
    transcriber: TranscriberProtocol,
    injector: InjectorProtocol,
    maxRecordingSeconds: Double = SyncSTTLimits.autoReleaseSeconds,
    clock: any Clock<Duration> = ContinuousClock(),
    keyTermsProvider: (@Sendable () -> [String])? = nil,
    styleNameProvider: (@Sendable () -> String?)? = nil,
    textShortcutsProvider: (@Sendable () -> [TextShortcut])? = nil,
    readinessCheck: @escaping @Sendable () -> BlurtError? = { nil },
    onTranscriptDelivered: (@Sendable (String, RecentDictations) -> Void)? = nil,
    seams: Seams
  ) {
    self.mic = mic
    self.transcriber = transcriber
    self.injector = injector
    self.maxRecordingSeconds = maxRecordingSeconds
    self.clock = clock
    self.keyTermsProvider = keyTermsProvider ?? { KeyTermsStore().terms }
    self.styleNameProvider =
      styleNameProvider
      ?? {
        // No rewrite means no style was applied — matching the transcriber's
        // own per-request read of the same store. `active` is nil for the
        // Default sentinel as well as for an empty list, which is exactly
        // the rule: only a *custom* style is worth naming on the row.
        guard EnhancedTranscriptsStore().isEnabled else { return nil }
        return StyleProfileStore().active?.name
      }
    self.textShortcutsProvider = textShortcutsProvider ?? { TextShortcutStore().shortcuts }
    self.readinessCheck = readinessCheck
    self.onTranscriptDelivered = onTranscriptDelivered
    self.seams = seams
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
    // The one door into a terminal state that is not a phase transition, so the
    // `setPhase` funnel never runs for it: a session dropped mid-recording would
    // otherwise leave its request to be wound down by continuation deallocation
    // rather than by the rule.
    upload?.cancel()
    commandFeed.finish()
    for continuation in continuations.values {
      continuation.finish()
    }
  }

  /// Appends `op` to the serial command queue and waits for it to run; the
  /// ordering guarantee is `chain`'s.
  func enqueue(_ op: @escaping @Sendable () async -> Void) async {
    await chain(op).value
  }

  /// Appends `op` to the serial command queue and hands back its handle
  /// *without* waiting — the half of `enqueue` a caller needs when something
  /// else must be able to reach the task while it runs. The synchronous
  /// read-then-write of `commandQueue` is what makes the chain order match the
  /// order the public methods executed their first actor turn.
  private func chain(_ op: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    let previous = commandQueue
    let task = Task {
      await previous?.value
      await op()
    }
    commandQueue = task
    return task
  }

  public func press() async {
    // Published before awaiting so a cancel can preempt the mic bring-up — see
    // `inFlightPress`. Cleared on the way out, but only if it's still ours.
    let task = chain { await self.performPress() }
    inFlightPress = task
    await task.value
    clearInFlightPress(task)
  }

  public func release() async {
    await enqueue { await self.performRelease() }
  }

  private func performRelease() async {
    guard phase == .recording else { return }
    cancelAutoRelease()
    // Flip the phase before stopping the mic, not after: the stop chime and
    // the pill's "Transcribing…" ride this transition, and mic.stop() waits out
    // the Bluetooth tail linger — up to 220 ms the user's "it heard me" cue
    // must not wait on. This also closes the double-release window: a second
    // release arriving during the mic.stop() suspension now fails the
    // `.recording` guard above instead of running the pipeline twice.
    setPhase(.transcribing)
    let recordedBytes: Int
    do {
      recordedBytes = try await mic.stop()
    } catch {
      // Both exits below set a terminal phase, and `setPhase` cancels the
      // in-flight request there — so a conformer whose `stop()` throws without
      // ending the feed can't leave it streaming until the idle timeout.
      // A cancel wins over surfacing the audio error — the user asked for
      // nothing to happen.
      if cancelWonRelease() { return }
      // Audio capture/conversion failed (e.g. the recorded file couldn't be
      // read back). Surface it instead of silently transcribing an empty blob.
      setPhase(.failed(.audioCaptureFailed(underlying: error)))
      return
    }
    // Honored again here, before any pipeline exists — deterministically no
    // transcription, no paste.
    if cancelWonRelease() { return }
    // A clip too short for the STT model (an accidental brief tap) comes back
    // 200-with-empty-text, not 400 (measured) — so drop it as a silent no-op
    // rather than paying for a request that transcribes nothing.
    //
    // Safe against the request finishing first, but no longer by winning a
    // race: with `config` leading the body the producer closes the request as
    // soon as `frames` ends, so it could beat this guard on a fast link. The
    // floor is enforced on the producer's side too — `streamedBody` refuses to
    // write the closing boundary below `minPCMBytes` — leaving this as the
    // quiet path to `.idle`, not the only thing keeping a tap off the wire.
    guard recordedBytes >= SyncSTTLimits.minPCMBytes else {
      setPhase(.idle)
      return
    }
    pipelineTask = Task { [weak self] in
      await self?.runTranscribeInject()
    }
  }

  /// Whether a cancel beat this release across the `mic.stop()` suspension, in
  /// which case the release must abandon the run. Both exits of `performRelease`
  /// ask, so the composite rule lives here rather than being spelled out twice —
  /// a new cancel route then reaches both exits by construction.
  ///
  /// Two routes: the cancel arrived synchronously (`cancel()` saw `.transcribing`
  /// and claimed the phase, moving it off `.transcribing`), or it was recorded
  /// before this release's turn and is consumed now.
  private func cancelWonRelease() -> Bool {
    consumeCancelRequest() || phase != .transcribing
  }

  /// Consumes a cancel requested while this release held the queue, claiming the
  /// phase for the user's cancel. Returns whether it fired.
  func consumeCancelRequest() -> Bool {
    guard cancelRequested else { return false }
    cancelRequested = false
    setPhase(.cancelled)
    return true
  }

  // `cancel()` and `performCancel()` — the user-intent cancel — live with the rest
  // of the command surface in `DictationSession+Commands.swift`, beside the
  // narrower `cancelRecording()`; both end up in `stopAndCancel` below.

  /// Shared tail of the cancel ops once the guards agree there is a live
  /// recording to tear down.
  func stopAndCancel() async {
    cancelAutoRelease()
    // Before the mic teardown, not after: `cancelCapture()` finishes the frame
    // stream, and a still-live upload would read that as "the utterance ended",
    // write its config part and transcribe audio the user just discarded.
    cancelUpload()
    do {
      // `cancelCapture`, not `stop`: the audio is being thrown away, so
      // preserving it (the Bluetooth tail linger) is not worth delaying the
      // user's cancel for.
      try await mic.cancelCapture()
    } catch {
      // Stays out of the UI: the user asked for nothing to happen, and a cancel
      // must not flash red (same rule as `performRelease`'s "a cancel wins over
      // surfacing the audio error"). But a mic teardown that genuinely failed was
      // reported nowhere at all, which made a recorder stuck mid-cancel
      // indistinguishable from a clean one. Record it for developer mode without
      // touching the phase — the log is exactly the channel for a fault the user
      // shouldn't be shown.
      seams.logFailure(.audioCaptureFailed(underlying: error), capturedContext)
    }
    setPhase(.cancelled)
  }

  private func cancelAutoRelease() {
    autoReleaseTask?.cancel()
    autoReleaseTask = nil
  }

  // The post-release pipeline — `runTranscribeInject` and its transcribe/inject
  // halves, plus the bounded context wait — lives in
  // `DictationSession+Pipeline.swift`, and `setPhase` (the one place a phase
  // change is published and a failure logged) with the rest of the observation
  // surface in `+Observation` (see the split note at the top).
}
