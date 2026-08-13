import BlurtEngine
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
  @ObservationIgnored private var phaseObserver: Task<Void, Never>?
  @ObservationIgnored private var levelsObserver: Task<Void, Never>?
  @ObservationIgnored var keyTap: DictationKeyTap?

  @ObservationIgnored private let transcriptStream: AsyncStream<RecentDictations>
  @ObservationIgnored private var transcriptObserver: Task<Void, Never>?

  /// The dictations that produced a transcript — pasted, copied, or even
  /// failed-to-paste (the seam fires before injection) — newest first, the first
  /// `displayCapacity` of them listed in the ready window's "Recent" section
  /// beneath the shortcut readout. In-memory only — starts empty each launch and
  /// is never written to disk.
  ///
  /// A **projection**, not a second ring: `DictationSession` owns the history
  /// (it builds each request's `conversation_context` from it, inside the actor)
  /// and pushes the updated value here, so this can't drift from what was
  /// actually sent. Nothing outside the session records into it.
  private(set) var recentDictations = RecentDictations()

  /// Live dictation status for the menu bar indicator (see `MenuBarLabel`).
  /// Updated in `render(_:)` alongside the overlay pill. The menu bar item is a
  /// convenience layered on the Dock app and can be hidden behind the notch on a
  /// crowded menu bar, so nothing here is relied on for correctness.
  private(set) var menuBarStatus: MenuBarStatus = .idle

  /// `components` defaults to the production pipeline; `apiKey` defaults to the
  /// production Keychain-backed model. Tests/UI-tests inject deterministic
  /// doubles (see `DictationComponents`) and an `APIKeyModel` built over an
  /// in-memory store with an offline validator — the engine's `APIKeySubmission`
  /// still owns the never-persist-an-unverified-key invariant either way.
  init(
    onSetupBlocked: @escaping @MainActor () -> Void,
    components: DictationComponents = .production(),
    apiKey: APIKeyModel = APIKeyModel()
  ) {
    self.onSetupBlocked = onSetupBlocked
    self.apiKey = apiKey

    // Buffering the newest is enough: each element is the *whole* ring as of that
    // delivery, not a delta, so a value dropped under contention is one the next
    // one already contains. (An append-only feed of individual transcripts had to
    // be unbounded, because there every dropped element was a lost dictation.)
    let (transcriptStream, transcriptContinuation) = AsyncStream.makeStream(
      of: RecentDictations.self, bufferingPolicy: .bufferingNewest(1))
    self.transcriptStream = transcriptStream

    self.mic = components.mic
    self.session = DictationSession(
      mic: components.mic,
      transcriber: components.transcriber,
      injector: components.injector,
      // A press with no key saved fails fast as .failed(.apiKeyMissing) —
      // before any capture — and render(_:) routes it to the settings window.
      readinessCheck: apiKey.readinessCheck(),
      // The session stamps and records each entry inside its own actor, so the
      // Recent row's time can't drift if this observer drains the buffer late
      // under contention — and the text needs no separate channel.
      onTranscriptDelivered: { _, recents in transcriptContinuation.yield(recents) }
    )
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

  func start() {
    // Pre-warm the mic so the first dictation doesn't pay hardware-route
    // discovery on the hot path — but only once microphone access is granted, so
    // warming up never triggers the permission prompt at launch. Before the grant
    // the user opts in via the setup screen's "Allow Microphone Access" button;
    // the first dictation after that just prepares a recorder lazily.
    if PermissionsChecker.check().microphone {
      let mic = mic
      Task { await mic.warmUp() }
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
    let session = session
    keyTap = DictationKeyTap(
      onStart: { session.submit(.press) },
      onStop: { session.submit(.release) },
      onCancel: { session.submit(.cancel) },
      // Recovery-only teardown; `cancelRecording()`'s doc owns the rationale.
      onRecordingDiscarded: { session.submit(.cancelRecording) }
    )
    // Deliberately *not* installed here: `CGEvent.tapCreate` for keystrokes is
    // itself what surfaces the system permission prompt, so creating the tap at
    // launch pops that prompt before the user ever reaches the "Grant
    // Accessibility" button in onboarding. The tap is instead installed by
    // `showOverlay()`, which the wizard calls on the transition into "ready" —
    // by then the process is trusted. On an already-configured launch that
    // transition fires from `WizardController.init`, so the tap still comes up.
  }

  /// Observes the session's phase stream (drives the pill + menu bar), the mic's
  /// level stream (drives the pill's meter), and the delivered-transcript stream
  /// (feeds the ready window's "Recent" list). One helper per stream keeps this
  /// method's cyclomatic complexity under SwiftLint's threshold.
  private func startPipelineObservers() {
    phaseObserver = observePhases()
    levelsObserver = observe(mic.levels) { $0.overlay?.pushLevel($1) }
    transcriptObserver = observe(transcriptStream) { $0.recentDictations = $1 }
  }

  private func observePhases() -> Task<Void, Never> {
    Task { @MainActor [weak self] in
      guard let phases = await self?.session.phaseStream() else { return }
      for await phase in phases {
        guard let self else { return }
        if Task.isCancelled { return }
        self.render(phase)
      }
    }
  }

  /// Spawns a MainActor observer that runs `action` for each value of `stream`
  /// until cancelled — the shared shape behind the level/transcript observers.
  /// (`observePhases` stays separate: it must `await` the session for its
  /// stream before it can loop.)
  private func observe<Value>(
    _ stream: AsyncStream<Value>,
    _ action: @escaping @MainActor (AppCoordinator, Value) -> Void
  ) -> Task<Void, Never> {
    Task { @MainActor [weak self] in
      for await value in stream {
        guard let self else { return }
        if Task.isCancelled { return }
        action(self, value)
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
  }

  // MARK: - Dictation render

  /// The record start/stop chimes (see `CueSoundPlayer` below).
  private let cues = CueSoundPlayer()

  /// Called when the user changes the sound pack in Settings: reload the cue
  /// players and preview the new voice so the choice is audible immediately.
  func soundPackChanged() {
    cues.packChanged()
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
    overlay?.show(state: phase.overlayState)
    // Mirror the phase onto the menu bar indicator (mapping lives in the engine,
    // unit-tested alongside `overlayState`).
    menuBarStatus = phase.menuBarStatus

    cues.transition(for: phase)

    // A dictation that ended without a key event (auto-release cap, a refused or
    // failed press) leaves the trigger's gate latched, which would swallow the
    // user's next press entirely. Clearing it here — the one place that sees every
    // phase — keeps the tap's state honest without the gate needing to know about
    // pipeline phases. No-op whenever the gate is already idle, which is every
    // normal flow.
    if phase.isTerminal {
      keyTap?.syncAfterTerminalPhase()
    }
  }
}
