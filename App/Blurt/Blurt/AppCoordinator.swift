import BlurtEngine
import Observation

@MainActor
@Observable
final class AppCoordinator {
  /// The dictation pill. Created lazily by `showOverlay()` — never at launch —
  /// so the panel and its SwiftUI host aren't built until the app is fully
  /// configured and the pill is about to appear. Stays nil through onboarding.
  private var overlay: OverlayWindowController?
  /// Invoked when the user triggers dictation without a saved API key. The app
  /// shell wires this to bring the setup/settings window forward so the user can
  /// add a key — the actionable fix — rather than flashing a message that
  /// disappears.
  let onMissingAPIKey: @MainActor () -> Void

  let session: DictationSession
  /// The mic seam, kept beyond session construction for its two side features —
  /// the loudness `levels` feed that drives the overlay meter and the `warmUp()`
  /// pre-open — both carried by `MicCaptureProtocol` itself (with no-op
  /// defaults), so stubs need supply neither.
  @ObservationIgnored private let mic: any MicCaptureProtocol
  /// Storage for the API key. Production hits the Keychain via `APIKeyStore`;
  /// UI tests inject an in-memory store so the real key is never touched.
  @ObservationIgnored private let keyStore: any APIKeyGateway
  /// True only under UI testing — short-circuits `submitAPIKey` past the network
  /// validation so the settings flow is deterministic and offline.
  @ObservationIgnored private let isUITesting: Bool
  private let keyValidator = APIKeyValidator()
  @ObservationIgnored private var phaseObserver: Task<Void, Never>?
  @ObservationIgnored private var levelsObserver: Task<Void, Never>?
  @ObservationIgnored private var promptObserver: Task<Void, Never>?
  /// Bridges the transcriber's per-utterance `onPromptAssembled` callback (fired
  /// off the main actor) into a stream `startPipelineObservers` consumes, so the
  /// Prompt Inspector's state is owned here alongside the other pipeline-derived
  /// state rather than in a global. `bufferingNewest(1)` because only the latest
  /// prompt matters.
  @ObservationIgnored private let promptStream: AsyncStream<String?>
  @ObservationIgnored var keyTap: DictationKeyTap?

  @ObservationIgnored private let transcriptStream: AsyncStream<String>
  @ObservationIgnored private var transcriptObserver: Task<Void, Never>?
  /// Clears `lastTranscript` after the dwell; re-created on each new transcript so
  /// only the latest schedules the revert.
  @ObservationIgnored private var echoRevertTask: Task<Void, Never>?

  /// How long a completed dictation's transcript stays in the ready window before
  /// reverting to the shortcut readout.
  private static let echoDwellSeconds: Double = 5

  /// The fully-assembled prompt sent to AssemblyAI on the most recent dictation,
  /// surfaced by the Prompt Inspector window (`nil` when none has been sent yet,
  /// or that dictation had no context to build one). In-memory only.
  private(set) var lastPrompt: String?

  /// The most recent completed dictation's transcript, shown in the ready window
  /// in place of the shortcut readout, or `nil` when the readout should show. Set
  /// on the `.pasted`/`.noTarget` outcomes, cleared when a new recording starts or
  /// after `echoDwellSeconds`. In-memory only.
  private(set) var lastTranscript: String?

  /// Whether an AssemblyAI API key is currently saved. Drives the wizard
  /// (which gates dictation on having a key) and the Settings UI.
  private(set) var hasAPIKey: Bool

  /// Live dictation status for the menu bar indicator (see `MenuBarLabel`).
  /// Updated in `render(_:)` alongside the overlay pill. The menu bar item is a
  /// convenience layered on the Dock app and can be hidden behind the notch on a
  /// crowded menu bar, so nothing here is relied on for correctness.
  private(set) var menuBarStatus: MenuBarStatus = .idle

  /// `components` is nil in production so this can wire the transcriber's prompt
  /// callback into `promptStream`; tests/UI-tests inject their own `components`
  /// (whose stub transcriber emits nothing, so the stream simply stays quiet).
  init(
    onMissingAPIKey: @escaping @MainActor () -> Void,
    components: DictationComponents? = nil,
    keyStore: any APIKeyGateway = ProductionAPIKeyStore(),
    isUITesting: Bool = false
  ) {
    self.onMissingAPIKey = onMissingAPIKey
    self.keyStore = keyStore
    self.isUITesting = isUITesting

    let (promptStream, promptContinuation) = AsyncStream.makeStream(
      of: String?.self, bufferingPolicy: .bufferingNewest(1))
    self.promptStream = promptStream
    let (transcriptStream, transcriptContinuation) = AsyncStream.makeStream(
      of: String.self, bufferingPolicy: .bufferingNewest(1))
    self.transcriptStream = transcriptStream
    let components =
      components
      ?? .production(
        onPromptAssembled: { promptContinuation.yield($0) })

    self.mic = components.mic
    self.session = DictationSession(
      mic: components.mic,
      transcriber: components.transcriber,
      injector: components.injector,
      // A press with no key saved fails fast as .failed(.apiKeyMissing) —
      // before any capture — and render(_:) routes it to the settings window.
      readinessCheck: { keyStore.hasKey ? nil : .apiKeyMissing },
      onTranscriptDelivered: { transcriptContinuation.yield($0) }
    )
    self.hasAPIKey = keyStore.hasKey
  }

  /// AppCoordinator lives for the whole app session, so these observers are
  /// never torn down in practice — but cancelling them here mirrors the care
  /// taken to keep them `[weak self]`, documenting that their lifetime is owned
  /// rather than leaked.
  deinit {
    phaseObserver?.cancel()
    levelsObserver?.cancel()
    promptObserver?.cancel()
    transcriptObserver?.cancel()
    echoRevertTask?.cancel()
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
  /// than a Carbon global hotkey: the latter leaks the chord's auto-repeat key
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
  /// level stream (drives the pill's meter), the assembled-prompt stream (feeds
  /// the Prompt Inspector), and the delivered-transcript stream (feeds the
  /// ready-window echo). Split into one helper per stream — rather than one
  /// `for await` loop per stream inline here — to keep this method's cyclomatic
  /// complexity under SwiftLint's threshold.
  private func startPipelineObservers() {
    phaseObserver = observePhases()
    levelsObserver = observeLevels()
    promptObserver = observePrompts()
    transcriptObserver = observeTranscripts()
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

  private func observeLevels() -> Task<Void, Never> {
    let levels = mic.levels
    return Task { @MainActor [weak self] in
      for await level in levels {
        guard let self else { return }
        if Task.isCancelled { return }
        self.overlay?.pushLevel(level)
      }
    }
  }

  private func observePrompts() -> Task<Void, Never> {
    let prompts = promptStream
    return Task { @MainActor [weak self] in
      for await prompt in prompts {
        guard let self else { return }
        if Task.isCancelled { return }
        self.lastPrompt = prompt
      }
    }
  }

  private func observeTranscripts() -> Task<Void, Never> {
    let transcripts = transcriptStream
    return Task { @MainActor [weak self] in
      for await transcript in transcripts {
        guard let self else { return }
        if Task.isCancelled { return }
        self.showTranscriptEcho(transcript)
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

  // MARK: - Dictation drivers
  //
  // The await-able begin/end/cancel path used by the UI-test harness
  // (`UITestSupport`). The key tap drives the same `DictationSession` through
  // its synchronous `submit(_:)` feed, so both paths hit the same engine
  // guards and race rules.

  /// Begins a dictation as the hotkey would (the missing-key gate is the
  /// session's `readinessCheck`; `render(_:)` routes the refusal to Settings).
  func beginDictation() async {
    await session.press()
  }

  /// Stops recording and runs transcribe→inject.
  func endDictation() async {
    await session.release()
  }

  /// Abandons the in-flight dictation.
  func cancelDictation() async {
    await session.cancel()
  }

  /// Called when the user rebinds (or clears) the dictation shortcut in the
  /// recorder, so the event tap starts matching the new chord. The shortcut no
  /// longer gates readiness (it has a default and lives in Settings), so there's
  /// nothing else to re-evaluate here.
  func dictationBindingChanged() {
    keyTap?.refreshBinding()
  }

  // MARK: - API key

  enum APIKeySubmissionResult: Equatable {
    case valid
    case invalid
    case unreachable
    case saveFailed
  }

  /// Saves the AssemblyAI API key and refreshes `hasAPIKey` so observers —
  /// including the wizard — react. Returns true only when a non-empty key is
  /// actually readable from Keychain after the write.
  @discardableResult
  func saveAPIKey(_ key: String) -> Bool {
    let saved = keyStore.set(key)
    hasAPIKey = keyStore.hasKey
    return saved && hasAPIKey
  }

  /// The key currently stored, read through the gateway. The setup/settings
  /// API-key view reads this (rather than `APIKeyStore` directly) so a UI-test
  /// run sees the injected in-memory store instead of the real Keychain.
  var currentAPIKey: String? { keyStore.get() }

  /// Re-reads the Keychain and updates `hasAPIKey`. The flag is otherwise only
  /// set at `init` and after `saveAPIKey`, so it can drift out of sync with what's
  /// actually stored — e.g. an early-launch Keychain read fails (the item's ACL
  /// needs re-approval after a re-sign) before a later read succeeds. Calling this
  /// when the API-key UI appears keeps the readiness gate honest: a key that's
  /// already present flips `hasAPIKey` true, so the wizard advances to the ready
  /// screen instead of stranding the user on a setup step whose only control (a
  /// *changed*-key "Update") is disabled.
  func refreshAPIKeyStatus() {
    let has = keyStore.hasKey
    if has != hasAPIKey { hasAPIKey = has }
  }

  /// Verifies `key` against AssemblyAI and saves it only when AssemblyAI
  /// actively accepts it (`.valid`). A rejected key (`.invalid`) or an
  /// unreachable server (`.unreachable`) is never saved — the wizard surfaces an
  /// inline error and the user retries — so an unverified key never persists.
  func submitAPIKey(_ key: String) async -> APIKeySubmissionResult {
    // UI tests must not reach AssemblyAI (no network in CI) or the real
    // Keychain, so resolve the result locally and deterministically instead.
    if isUITesting { return uiTestSubmit(key) }
    let result = await keyValidator.validate(key)
    switch result {
    case .valid:
      return saveAPIKey(key) ? .valid : .saveFailed
    case .invalid:
      return .invalid
    case .unreachable:
      return .unreachable
    }
  }

  /// Offline stand-in for `submitAPIKey` under UI testing. Sentinel keys drive
  /// the failure branches so a test can exercise the inline-error paths; any
  /// other non-empty key is accepted and saved to the in-memory store.
  private func uiTestSubmit(_ key: String) -> APIKeySubmissionResult {
    switch key {
    case UITestKeys.invalidAPIKey: return .invalid
    case UITestKeys.unreachableAPIKey: return .unreachable
    default: return saveAPIKey(key) ? .valid : .saveFailed
    }
  }

  // MARK: - Dictation render

  /// The record start/stop chimes (see `CueSoundPlayer` below).
  private let cues = CueSoundPlayer()

  /// Called when the user changes the sound pack in Settings: reload the cue
  /// players and preview the new voice so the choice is audible immediately.
  func soundPackChanged() {
    cues.packChanged()
  }

  /// Shows `text` in the ready window and schedules its revert. A new transcript
  /// cancels and reschedules the pending revert so the latest wins.
  private func showTranscriptEcho(_ text: String) {
    lastTranscript = text
    echoRevertTask?.cancel()
    echoRevertTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(AppCoordinator.echoDwellSeconds))
      guard let self, !Task.isCancelled else { return }
      self.lastTranscript = nil
    }
  }

  private func render(_ phase: PipelinePhase) {
    // A missing key is a setup state, not a fault: the engine projections
    // below render it as calm idle (no red flash) and Monitoring ignores it —
    // the only app-level part is the navigation side effect, bringing the
    // settings window forward so the user lands on the fix.
    if case .failed(.apiKeyMissing) = phase {
      onMissingAPIKey()
    }
    // A new recording resets the ready window to the plain readout — the previous
    // result shouldn't linger while the user dictates the next one.
    if phase == .recording {
      echoRevertTask?.cancel()
      lastTranscript = nil
    }
    // Reveal the pill first, then fire the cue: the sound must never sit in
    // front of the visual state change. Pure phase→pill mapping lives in the
    // engine (unit-tested there); .failed resolves to .error, which the pill
    // flashes red then auto-reverts to idle.
    overlay?.show(state: phase.overlayState)
    // Mirror the phase onto the menu bar indicator (mapping lives in the engine,
    // unit-tested alongside `overlayState`).
    menuBarStatus = phase.menuBarStatus

    cues.transition(isRecording: phase == .recording)
  }
}
