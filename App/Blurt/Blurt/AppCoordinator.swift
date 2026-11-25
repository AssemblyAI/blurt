import AppKit
import AssemblyAI
import BlurtAssemblyAI
import BlurtEngine
import Foundation
import Observation

@Observable
final class AppCoordinator {
  /// The dictation pill. Created lazily by `showOverlay()` — never at launch —
  /// so the panel and its SwiftUI host aren't built until the app is fully
  /// configured and the pill is about to appear. Stays nil through onboarding.
  private var overlay: OverlayWindowController?
  /// Invoked when a press is refused because setup isn't finished — today a
  /// missing API key, and whatever else the engine classifies as a
  /// `PipelinePhase.setupBlocker`. The app shell wires this to bring the
  /// setup/settings window forward so the user lands on the actionable fix rather
  /// than seeing a message that disappears.
  let onSetupBlocked: @MainActor () -> Void

  let session: DictationSession
  /// The mic seam, kept beyond session construction for its two side features —
  /// the loudness `levels` feed that drives the overlay meter and the `warmUp()`
  /// pre-open — both carried by `MicCaptureProtocol` itself (with no-op
  /// defaults), so stubs need supply neither.
  @ObservationIgnored private let mic: any MicCaptureProtocol
  /// The API-key surface (storage seam, validate-then-save flow, and the
  /// observable `hasAPIKey` flag), extracted so the coordinator stays focused on
  /// pipeline↔UI wiring. The wizard and the API-key view observe this directly
  /// rather than reaching through the coordinator (see `APIKeyModel`).
  let apiKey: APIKeyModel
  /// "Sign in with AssemblyAI", which fills the same key `apiKey` holds. Its
  /// configuration comes from Info.plist; a build without one hides sign-in.
  let account: AssemblyAIAccount
  @ObservationIgnored private var phaseObserver: Task<Void, Never>?
  @ObservationIgnored private var levelsObserver: Task<Void, Never>?
  @ObservationIgnored var keyTap: DictationKeyTap?
  /// Routes the trigger's commands to dictation, or to read-aloud when the
  /// experimental switch is on and text is selected. It also decides the gate
  /// resets (see `SelectionSpeechRouting`).
  @ObservationIgnored private var speechRouter: SelectionSpeechRouter?

  @ObservationIgnored private let transcriptStream: AsyncStream<RecentDictations>
  @ObservationIgnored private var transcriptObserver: Task<Void, Never>?

  /// Live dictation status for the menu bar indicator (see `MenuBarLabel`).
  /// Updated in `render(_:)` alongside the overlay pill. The menu bar item is a
  /// convenience layered on the Dock app and can be hidden behind the notch on a
  /// crowded menu bar, so nothing here is relied on for correctness.
  private(set) var menuBarStatus: MenuBarStatus = .idle
  /// Whether the mic is being brought up or capturing (`PipelinePhase
  /// .isCapturing`) — while it is, Esc in the ready screen cancels the
  /// dictation. Nothing on that screen changes with it: the pill shows how a
  /// dictation is going.
  private(set) var isCapturing = false
  /// The last phase rendered, so the pill can go back to it when a read ends.
  @ObservationIgnored private var lastPhase = PipelinePhase.idle
  /// Whether a read or answer is playing — the pill shows it; UI tests read it.
  private(set) var isReadingAloud = false
  /// What reads aloud and how the selection is read, when not the real ones:
  /// UI tests run the whole read-aloud path offline. Nil in production.
  @ObservationIgnored private let triggerKeySeams: TriggerKeySeams?
  /// The saved history — every dictation, dropped or browsed-for file and
  /// recording — and the transcript sheet's state for whichever is open.
  let transcripts: TranscriptsModel

  // MARK: - Dictation render

  /// The record start/stop chimes (`CueSoundPlayer` below), and the music pause on the same edges.
  private let cues = CueSoundPlayer()
  private let media = MediaPauseController()

  /// `components` defaults to the production pipeline, its transcriber dictating
  /// against the account's `dictationOrigin`; `apiKey` defaults to the
  /// production Keychain-backed model. Tests/UI-tests inject deterministic
  /// doubles (see `DictationComponents`) and an `APIKeyModel` built over an
  /// in-memory store with an offline validator — the engine's `APIKeySubmission`
  /// still owns the never-persist-an-unverified-key invariant either way.
  init(
    onSetupBlocked: @escaping @MainActor () -> Void,
    components: DictationComponents? = nil,
    apiKey: APIKeyModel = APIKeyModel(),
    account: AssemblyAIAccount? = nil,
    triggerKeys: TriggerKeySeams? = nil,
    transcripts: TranscriptsModel? = nil
  ) {
    self.onSetupBlocked = onSetupBlocked
    self.triggerKeySeams = triggerKeys
    self.apiKey = apiKey
    let info = Bundle.main.infoDictionary ?? [:]
    let resolvedAccount =
      account
      ?? AssemblyAIAccount(
        configuration: .blurt(infoDictionary: info),
        apiKey: apiKey,
        dictationHost: OAuthConfiguration.blurtDictationOrigin(infoDictionary: info)
      )
    self.account = resolvedAccount
    let resolvedComponents =
      components
      ?? .production(dictationOrigin: resolvedAccount.dictationOrigin) {
        Task { await resolvedAccount.keyWasRejected() }
      }

    // Buffering the newest is enough: each element is the *whole* ring as of that
    // delivery, not a delta, so a value dropped under contention is one the next
    // one already contains. (An append-only feed of individual transcripts had to
    // be unbounded, because there every dropped element was a lost dictation.)
    let (stream, transcriptContinuation) = AsyncStream.makeStream(
      of: RecentDictations.self, bufferingPolicy: .bufferingNewest(1)
    )
    self.transcriptStream = stream

    self.mic = resolvedComponents.mic
    self.transcripts = transcripts ?? TranscriptsModel()
    self.transcripts.setAutoRecordMeetings(MeetingAutoRecordStore().isEnabled)
    self.session = DictationSession(
      mic: resolvedComponents.mic,
      transcriber: resolvedComponents.transcriber,
      injector: resolvedComponents.injector,
      // A press with no key saved fails fast as .failed(.apiKeyMissing) —
      // before any capture — and render(_:) routes it to the settings window.
      readinessCheck: apiKey.readinessCheck()
    ) { _, recents in
      // The session stamps and records each entry inside its own actor, so the
      // Recent row's time can't drift if this observer drains the buffer late
      // under contention — and the text needs no separate channel.
      transcriptContinuation.yield(recents)
    }
  }

  func start() {
    // Before the first read of the binding — the override below, the key tap,
    // and every view's `@AppStorage` copy all come after `start()`.
    TriggerKeyStore().migrateStaleFunctionBinding()
    syncGlobeKeyOverride()
    // Absorb the one-off cost of this process's first touch of the capture
    // stack, so the first dictation doesn't pay it on the hot path (~75 ms; see
    // `MicCapture.warmUp()`, which holds no recorder and opens no device). Gated
    // on the grant because building a capture input is what raises the
    // microphone prompt, and launch is the wrong moment for it: before the grant
    // the user opts in via the setup screen's "Allow Microphone Access" button,
    // and the first dictation after that simply pays the build itself.
    if PermissionsChecker.check().microphone {
      let capture = mic
      Task { await capture.warmUp() }
    }
    // Note: no initial overlay render. The overlay pill stays hidden until the
    // app is fully configured — `WizardController` calls `showOverlay()` on the
    // transition into "ready" (and `hideOverlay()` if it later breaks).
    startDictationDriver()
    startPipelineObservers()
  }

  /// Builds the key tap, wired straight into the session's synchronous
  /// `submit(_:)` command feed (see its doc for the FIFO-ordering guarantee
  /// that rules out spawning a `Task {}` per callback). Drives the
  /// hold-to-dictate hotkey from a CGEventTap (see `DictationKeyTap`) rather
  /// than a Carbon global hotkey: the latter leaks the trigger's auto-repeat key
  /// events into the focused app while held.
  private func startDictationDriver() {
    let router = makeSpeechRouter()
    keyTap = DictationKeyTap(
      // The key rides the press, and the session resolves its style for that one
      // dictation (`PressStyle`); the main window's selection is never written.
      // The cues hear of the key first, so the recording or read it starts
      // opens in that key's voice.
      onStart: { [weak self] key in
        self?.cues.keyPressed(key)
        router.press(key: key)
      },
      onStop: { router.submit(.release) },
      onCancel: { router.submit(.cancel) },
      onLatch: { router.keyLatched() },
      // Recovery-only teardown; `cancelRecording()`'s doc owns the rationale.
      onRecordingDiscarded: { router.submit(.cancelRecording) },
      onEscape: { router.escape() },
      isBusy: { router.isBusy }
    )
    router.syncGateAfterSession = { [weak self] in self?.keyTap?.syncAfterTerminalPhase() }
    router.resetGate = { [weak self] in self?.keyTap?.resetGate() }
    wirePill(to: router)
    speechRouter = router
    // Deliberately *not* installed here: `CGEvent.tapCreate` for keystrokes is
    // itself what surfaces the system permission prompt, so creating the tap at
    // launch pops that prompt before the user ever reaches the "Grant
    // Accessibility" button in onboarding. The tap is instead installed by
    // `showOverlay()`, which the wizard calls on the transition into "ready" —
    // by then the process is trusted. On an already-configured launch that
    // transition fires from `WizardController.init`, so the tap still comes up.
  }

  /// Every trigger command goes through the read-aloud router, which forwards
  /// a dictating key's commands to `session.submit` and handles read and ask
  /// keys itself.
  private func makeSpeechRouter() -> SelectionSpeechRouter {
    guard let seams = triggerKeySeams else {
      return SelectionSpeechRouter(
        session: session,
        services: .assemblyAI(),
        // Every read is kept, findable and playable from the Recent list.
        clips: ReadClipSink(directory: TranscriptStore.readAloudDirectory) { [weak self] clip in
          Task { @MainActor in self?.transcripts.saveReadClip(clip) }
        }
      )
    }
    return SelectionSpeechRouter(
      session: session,
      speaker: seams.speaker,
      rewriter: seams.rewriter,
      composer: seams.composer,
      planner: seams.planner,
      performer: seams.performer,
      readSelection: seams.readSelection
    )
  }

  /// Hooks the router's reads and jobs up to the pill, the cues and the music
  /// pause.
  private func wirePill(to router: SelectionSpeechRouter) {
    // A read wears the dictation pill — orb and meter, the meter following the
    // voice — between the same start and stop cues. Pill first, then the cue,
    // as `render(_:)` orders them.
    router.speechStarted = { [weak self] in
      self?.isReadingAloud = true
      self?.overlay?.show(state: .speaking)
      self?.cues.speechStarted()
    }
    router.speechEnded = { [weak self] in
      guard let self else {
        return
      }
      isReadingAloud = false
      // Back to what the session is doing — a capture or transcription still
      // under way — and never a dictation's old notice (the engine's rule).
      overlay?.show(state: lastPhase.overlayStateAfterSpeech)
      cues.speechEnded()
    }
    // A rewrite or a command shows as working while it runs, then as its
    // outcome: Pasted (Done, for a command), Copied or the error, the notices a
    // dictation ends with. Abandoned by a press, the pill goes back to what the
    // session is doing.
    router.jobPill = { [weak self] state in
      guard let self else {
        return
      }
      overlay?.show(state: state ?? lastPhase.overlayStateAfterSpeech)
    }
    router.speechLevel = { [weak self] level in self?.overlay?.pushLevel(level) }
    // An ask's music stays paused through its answer, a job's until it's done.
    router.pressSettled = { [weak self] in self?.media.pressSettled() }
    // The pill just goes away on a failed read, so say something went wrong.
    router.speechFailed = { _ in NSSound.beep() }
  }

  /// Observes the session's phase stream (drives the pill + menu bar), the mic's
  /// level stream (drives the pill's meter), and the delivered-transcript stream
  /// (feeds the ready window's "Recent" list). One helper per stream keeps this
  /// method's cyclomatic complexity under SwiftLint's threshold.
  private func startPipelineObservers() {
    phaseObserver = observePhases()
    levelsObserver = observe(mic.levels) { $0.overlay?.pushLevel($1) }
    // `DictationSession` owns the ring of recent dictations (its request
    // context); each entry it gains is saved to the history.
    transcriptObserver = observe(transcriptStream) { $0.transcripts.saveDictations(from: $1) }
  }

  private func observePhases() -> Task<Void, Never> {
    Task { [weak self] in
      guard let phases = await self?.session.phaseStream() else {
        return
      }
      for await phase in phases {
        guard let self else {
          return
        }
        if Task.isCancelled {
          return
        }
        render(phase)
      }
    }
  }

  /// Arms the dictation pill. Called by the wizard once the app is fully
  /// configured. The pill itself stays hidden until a dictation starts — it only
  /// appears while you're holding (or after you tap) the key, then fades out when
  /// the pipeline returns to idle. This just installs the key tap and builds the
  /// (initially hidden) pill controller.
  func showOverlay() {
    // Setup is complete here, so the process is trusted — this is the first and
    // only place the key tap is installed. Creating it earlier (e.g. at launch)
    // would surface the permission prompt before onboarding; see `start()`.
    keyTap?.ensureRunning()
    // Build the pill controller now (first point it's needed) but leave it
    // hidden; `render(_:)` reveals it on the transition into `.recording`.
    if overlay == nil { overlay = OverlayWindowController() }
    // Pre-roll the start/stop cues now that the app is ready, so the first
    // chime's audio-queue setup never stalls the recording pill.
    cues.prime()
  }

  /// Hides the overlay pill. Called by the wizard when the app stops being fully
  /// configured, so the pill is never on screen while dictation can't work.
  func hideOverlay() {
    overlay?.hide()
  }

  /// Called when the user rebinds the dictation trigger in the Shortcut picker,
  /// so the event tap starts matching the new key. The shortcut no longer gates
  /// readiness (it has a default and lives in Settings), so there's nothing else
  /// to re-evaluate here.
  func dictationBindingChanged() {
    keyTap?.refreshBinding()
    syncGlobeKeyOverride()
    // A key with no voice of its own follows its action's, so a new action
    // can mean a new voice to load.
    cues.refresh()
  }

  /// Called when the user changes a key's sound in Settings: reload that key's
  /// cue players and preview the new voice so the choice is audible immediately.
  func keySoundChanged(_ key: TriggerKey) {
    cues.packChanged(for: key)
  }

  /// The Read Aloud tab picked a voice or a speed: play a sample in it, as a cue
  /// sound plays when it's picked.
  func readAloudStyleChanged() {
    speechRouter?.previewSample()
  }

  private func render(_ phase: PipelinePhase) {
    // A setup blocker is a state, not a fault: the engine projections below
    // render it as calm idle (no red flash) and the menu bar ignores it — the only
    // app-level part is the navigation side effect, bringing the settings window
    // forward so the user lands on the fix. Which failures count as setup is the
    // engine's call (`PipelinePhase.setupBlocker`), not re-derived here.
    if phase.setupBlocker != nil {
      onSetupBlocked()
    }
    // Reveal the pill first, then fire the cue: the sound must never sit in
    // front of the visual state change. Pure phase→pill mapping lives in the
    // engine (unit-tested there); .failed resolves to .error, which the pill
    // flashes red then auto-reverts to idle.
    // A read wears the pill until it ends (the engine's rule — see
    // `overlayState(whileSpeaking:)`).
    lastPhase = phase
    // A rewrite press's instruction transcribes as "Rewriting", and a command
    // press's as "Working", not "Transcribing".
    if let state = phase.overlayState(
      whileSpeaking: speechRouter?.ownsPill ?? false, processingAs: speechRouter?.processingState
    ) {
      overlay?.show(state: state)
    }
    // Mirror the phase onto the menu bar indicator (mapping lives in the engine,
    // unit-tested alongside `overlayState`).
    menuBarStatus = phase.menuBarStatus
    // And onto the ready screen, for its Esc-to-cancel: the same stream the
    // pill renders, never a second source.
    isCapturing = phase.isCapturing

    cues.transition(for: phase)
    media.transition(for: phase, recordsCommand: speechRouter?.recordsCommand ?? false)

    // A dictation that ended without a key event (auto-release cap, a refused or
    // failed press) leaves the trigger's gate latched, which would swallow the
    // user's next press entirely. Clearing it here — the one place that sees every
    // phase — keeps the tap's state honest without the gate needing to know about
    // pipeline phases. No-op whenever the gate is already idle, which is every
    // normal flow. Asked through the router, because while a read-aloud owns the
    // gate the reset isn't this dictation's to make (see `SelectionSpeechRouting`).
    // It gets the phase itself because an ask about a selection ends in one,
    // `.handedBack`, carrying the transcript the router answers — and every
    // phase, not just the terminal ones, so it can tell an earlier dictation
    // still finishing from the end of a request it is waiting on.
    speechRouter?.sessionPhaseChanged(phase)
  }

  /// AppCoordinator lives for the whole app session, so these observers are
  /// never torn down in practice — but cancelling them here mirrors the care
  /// taken to keep them `[weak self]`, documenting that their lifetime is owned
  /// rather than leaked.
  deinit {
    phaseObserver?.cancel()
    levelsObserver?.cancel()
    transcriptObserver?.cancel()
  }
}
