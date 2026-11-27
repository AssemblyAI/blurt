import BlurtAssemblyAI
import BlurtEngine
import BlurtiOSCore
import Foundation
import Observation
import UIKit

/// The one place the engine is composed for the iPhone app — the role
/// `AppCoordinator` plays in the Mac shell. It owns the listening window (the
/// microphone), the session, and the two channels to the keyboard: commands
/// coming in over the App Group, phase and results going back out. Every
/// command is answered (`CommandRouter`, `DictationCoordinator+Commands.swift`),
/// every dictation has an owner, and one whose keyboard is gone is ended by
/// the watchdog rather than left recording.
///
/// Key terms live in the App Group (`SharedStore.keyTerms`) rather than the
/// engine's `KeyTermsStore` (which reads the process's own defaults), so the
/// keyboard can add one on the spot; `keyTermsProvider` is how they reach the
/// request.
@MainActor
@Observable
final class DictationCoordinator {
  /// A press and the field it came from, as `DictationHandoff` holds it:
  /// pending until the session takes it, then the dictation's.
  nonisolated struct Press: Sendable {
    /// The field the press came from.
    var address = ResultAddress()
    var context = FocusedFieldContext.empty
    /// The field whose accepted stop ended the dictation, which is where the
    /// words go. The dictation itself and its owner are `inFlight`.
    var stopAddress: ResultAddress?
  }

  static let log = HostIdentity.current.logger("Commands")
  /// The background task held from a release to the dictation's end, so the
  /// words land after the keyboard's host put Blurt in the background.
  static let releaseTask = "blurt.release"
  /// How often, while a dictation is in flight, the owner's presence is
  /// checked (`OwnerWatchdog`): a dead keyboard's dictation is released at
  /// most this long after `BlurtShared.ownerWatchdog` has passed since its
  /// last beat (DESIGN.md). The `keyboard` signal asks at once besides.
  static let watchdogTick: Duration = .seconds(2)
  let window: ListeningWindow
  let apiKey: APIKeyModel
  /// The App Group the keyboard is reached through: the window's, so the two
  /// can't write to different ones.
  let store: SharedStore
  /// This process's own defaults, apart from the App Group: consent, the
  /// session switch's off, the stats.
  @ObservationIgnored let defaults: UserDefaults
  /// The presses and words the session's seams read off the main actor.
  @ObservationIgnored let handoff: DictationHandoff
  private(set) var phase: PipelinePhase = .idle
  private(set) var recent = RecentDictations()
  private(set) var level: Float = 0
  /// Set by `startListening` (`DictationCoordinator+Window.swift`), which
  /// the file split keeps from being `private(set)`.
  var microphoneDenied = false
  /// The keyboard brought the app forward from another app to start a
  /// session (`blurt://start`): the home screen points at iOS's "◀ App" back
  /// link until the user leaves. Not when the keyboard was already in Blurt's
  /// own box: iOS shows no back link then.
  var startedFromKeyboard = false
  /// The keyboard brought the app forward because it has no Full Access
  /// (`blurt://setup?need=fullAccess`): the setup step says what to turn on,
  /// and no window is opened, until the user leaves.
  var needsFullAccess = false
  /// The app the keyboard hopped from (`BlurtShared.hopHost`), held until the
  /// window is open and the app has gone back to it (`HopReturn`,
  /// `HostReturn`), or the window failed to open, or the user left first.
  @ObservationIgnored var returnHost: String?
  /// The return's cap, armed when the window opens before the keeper is up
  /// (`BlurtShared.hopReturnCap`).
  @ObservationIgnored var returnCap: Task<Void, Never>?
  /// A record since the hop said opening or open: only then does a closed
  /// one mean the open failed, rather than the launch record before it.
  @ObservationIgnored var returnSawWindow = false
  /// Whether a Picture in Picture keeper has to be up before the app may
  /// leave; nil reads the window's idle mode (a test sets it), so it is a
  /// tri-state rather than a flag.
  @ObservationIgnored var expectsKeeper: Bool?  // swiftlint:disable:this discouraged_optional_boolean
  /// How many contact names the keyboard last read off the phone — the key
  /// terms that come for free, so the home screen can say so.
  private(set) var lexiconNameCount = 0
  /// A shared key-term list the app was asked to open, until the user has
  /// answered it (`ImportTermsView`).
  var pendingTermPack: TermPack?
  /// A file or link that claimed to be a key-term list and wasn't.
  var termPackUnreadable = false
  /// The window can't open without a key: the last try to enable Blurt said so.
  var needsKey = false
  /// The window can't open until the user agrees to AssemblyAI processing their
  /// voice (`AIConsent`); `ConsentView` asks while this is set.
  var needsConsent = false
  /// A failed dictation's sentence for the home card: for `HomeStatus.errorDwell`,
  /// or until the window's state changes, whichever is sooner.
  private(set) var error: String?

  @ObservationIgnored let session: DictationSession
  /// What the watchdog's tick sleeps on; injectable so tests advance it.
  @ObservationIgnored let clock: any Clock<Duration>
  @ObservationIgnored private let recents: AsyncStream<RecentDictations>
  @ObservationIgnored private var observers: [DarwinObserver] = []
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var errorDwell: Task<Void, Never>?
  /// The owner's watchdog, ticking `watchdogTick` while a dictation is in
  /// flight and cancelled at its end (`DictationCoordinator+Commands.swift`).
  @ObservationIgnored var watchdog: Task<Void, Never>?
  /// The keyboard command the app last took: the press this phase answers,
  /// or the release or cancel that ended it (`PhaseSnapshot.command`).
  @ObservationIgnored var lastCommandID: UUID?
  /// Command ids answered and how, so a resend is answered the same way; the
  /// most recent `answeredCapacity`, in order.
  @ObservationIgnored var answered: [UUID: CommandAck.Outcome] = [:]
  @ObservationIgnored var answeredOrder: [UUID] = []
  /// The dictation the last accepted press started, until its terminal
  /// phase: what the router and the watchdog decide on, and what every phase
  /// in between names.
  @ObservationIgnored var inFlight: DictationRef?
  /// The press `inFlight` answers, carried on every phase through its terminal one.
  @ObservationIgnored var answers: UUID?
  /// The dictation the watchdog already released, so a stuck one is released once.
  @ObservationIgnored var watchdogReleased: UUID?
  /// The dictation a keyboard's release or cancel was accepted for
  /// (`stopped` / `cancelled` answered): its end is on its way through the
  /// session, so the watchdog has nothing to add — the keyboard's own release
  /// as it disappears must not be followed by a second one.
  @ObservationIgnored var stopAccepted: UUID?
  /// A recording is in flight, as the window was told.
  @ObservationIgnored private var utteranceOpen = false
  /// Time since the meter last published, on `clock` (`stopwatch(on:)`).
  @ObservationIgnored private var sinceLevelPublish: () -> Duration
  /// When the recording in progress started (the keyboard's countdown reads
  /// it off the phase), and how long the last one ran.
  @ObservationIgnored private(set) var recordingSince: Date?
  @ObservationIgnored private var lastSpokenSeconds: Double = 0

  /// The time the keyboard's presence is judged against — by a press's
  /// decision, the owner's watchdog and the words' delivery — so a test's
  /// "seen 11 s ago" stays 11 s however slowly the run goes.
  @ObservationIgnored let now: @Sendable () -> Date
  /// Whether the app is in front, as `handle(url)` reads it; a test's stand-in.
  @ObservationIgnored let appState: @MainActor () -> UIApplication.State
  /// Brings the host app back (`HostReturn.open`); a test's capture.
  @ObservationIgnored let hostReturner: @MainActor (String) -> Bool

  /// The phase as the home screen and the keyboard show it, in the engine's
  /// wording — a capture failure in the source's own sentence, since
  /// `ListeningSourceFailure` is `CaptureFailureWording`.
  var overlay: OverlayUIState { phase.overlayState }

  /// The window — and with it the App Group (`store`) — and this process's
  /// `defaults` are the composition root's to pass: `.live` and `.standard`
  /// in the app, a scratch suite of each in a test. `transcriber`, `clock`
  /// and `now` are seams for the tests, which drive a press through the real
  /// session against a stub transcript, a clock they advance and an instant
  /// they hold; the app keeps the defaults.
  init(
    window: ListeningWindow,
    defaults: UserDefaults,
    apiKey: APIKeyModel = APIKeyModel(),
    transcriber: any TranscriberProtocol = AssemblyAITranscriber(),
    clock: any Clock<Duration> = ContinuousClock(),
    now: @escaping @Sendable () -> Date = { Date() },
    appState: @escaping @MainActor () -> UIApplication.State = { UIApplication.shared.applicationState },
    hostReturner: @escaping @MainActor (String) -> Bool = HostReturn.open(bundleID:)
  ) {
    self.window = window
    self.apiKey = apiKey
    self.store = window.store
    self.defaults = defaults
    let seams = DictationHandoff(store: window.store)
    handoff = seams
    self.clock = clock
    sinceLevelPublish = Self.stopwatch(on: clock)
    self.now = now
    self.appState = appState
    self.hostReturner = hostReturner
    let (recentStream, continuation) = AsyncStream.makeStream(
      of: RecentDictations.self, bufferingPolicy: .bufferingNewest(1)
    )
    self.recents = recentStream
    session = DictationSession(
      mic: window.source,
      transcriber: transcriber,
      // The words go to the keyboard that sent the accepted stop, else to
      // the one whose press started the dictation. Delivery waits on the
      // coordinator's clock and judges presence by its `now`, as the
      // watchdog does.
      injector: KeyboardRelayInjector(
        store: window.store,
        presser: { seams.claimedPress.withLock { $0.stopAddress ?? $0.address } },
        clock: clock,
        now: now
      ),
      keyTermsProvider: { seams.keyTerms() },
      readinessCheck: apiKey.readinessCheck(),
      onTranscriptDelivered: { text, ring in
        seams.deliveredText.withLock { $0 = text }
        continuation.yield(ring)
      },
      // The keyboard is the only thing that can see the field: the press
      // command carries the text before the cursor, and that is what primes
      // the request — the same signal the Mac reads through Accessibility.
      // `frontmost` runs only for a press the session accepts, first thing, so
      // that is where the press's keyboard and field text become the dictation's.
      hostFocusCapture: DictationSession.HostFocusCapture(
        frontmost: { seams.claimPress() }, field: { seams.fieldContext() }
      )
    )
    window.onEndingUtterance = { [weak self] keepWords in await self?.endUtterance(keepWords: keepWords) }
    window.onStateChanged = { [weak self] _ in self?.clearError() }
    window.onRecord = { [weak self] record in self?.recordPublished(record) }
  }

  /// How long it has been on `clock` since this call, read each time the
  /// result is called: the meter's throttle times itself on the injected clock
  /// rather than the device's, as every other timer here does. Generic, so the
  /// instant it keeps is the clock's own type.
  private static func stopwatch<C: Clock>(on clock: C) -> () -> Duration where C.Duration == Duration {
    let start = clock.now
    return { start.duration(to: clock.now) }
  }

  func start() {
    // `.task` on the root view runs this once; a scene reconnect must not
    // start a second set of observers publishing every phase twice.
    guard tasks.isEmpty else {
      return
    }
    // Whatever the last run left in the App Group is over: a fresh launch,
    // no window, and the phase idle under it. The window's heartbeat runs
    // from here for as long as the process does.
    window.start()
    observers = [
      store.observe(BlurtShared.Signal.command) { [weak self] in
        Task { @MainActor in self?.handleCommand() }
      },
      store.observe(BlurtShared.Signal.keyboard) { [weak self] in
        Task { @MainActor in self?.tickWatchdog() }
      },
      store.observe(BlurtShared.Signal.lexicon) { [weak self] in
        Task { @MainActor in self?.reloadLexicon() }
      },
    ]
    reloadLexicon()
    tasks = [observePhases(), observeLevels(), observeRecents()]
    publish(.idle)
  }

  // MARK: - Key terms

  private func reloadLexicon() {
    let entries = store.read([LexiconEntry].self, forKey: BlurtShared.Key.lexicon) ?? []
    let names = entries.filter(\.isName).map(\.documentText)
    handoff.lexiconNames.withLock { $0 = names }
    lexiconNameCount = names.count
  }

  // MARK: - Phase, level and results out to the keyboard

  private func observePhases() -> Task<Void, Never> {
    let pipeline = session
    // Only this loop renders, so `phase` is still what the screen shows when
    // the subscription is taken: the session skips replaying it (#413).
    let shown = phase
    return Task { [weak self] in
      for await nextPhase in await pipeline.phaseStream(alreadyShowing: shown) {
        guard let self else {
          return
        }
        render(nextPhase)
      }
    }
  }

  /// One phase, in order: the window hears when a recording starts and when
  /// it stops (the window's lifetime counts from the last word, so the stop
  /// is the end of the recording, not of the transcript), the keyboard reads
  /// the phase with the press it answers and the dictation it names, and a
  /// terminal phase ends the dictation's ownership and its background task.
  func render(_ phase: PipelinePhase) {
    self.phase = phase
    if phase == .recording {
      if !utteranceOpen {
        utteranceOpen = true
        recordingSince = now()
        window.utteranceStarted()
      }
    } else if utteranceOpen {
      // The recording is over; how long it ran is kept for the stats.
      utteranceOpen = false
      if let since = recordingSince { lastSpokenSeconds = now().timeIntervalSince(since) }
      window.utteranceEnded()
    }
    if phase.isTerminal { recordingSince = nil }
    // Delivery always comes before the paste and its terminal phase, and the
    // phases render in order, so the dictation's words are waiting by now.
    if phase.isTerminal,
      let text = handoff.deliveredText.withLock({ text in
        defer { text = nil }
        return text
      })
    {
      DictationStats.record(text, spokenFor: lastSpokenSeconds, in: defaults)
    }
    // A press's start that failed is the window's news too: the source is
    // lost until the next foreground (a refused background start), or until
    // it resumes (a call, a dead or silent mic). The session being off is not.
    if case .failed(.audioCaptureFailed(let underlying)) = phase {
      window.captureFailed(reason: CaptureFailure.reason(for: underlying))
    }
    // The Mac shows a setup blocker as calm idle beside a settings button;
    // the keyboard has no such button, so it hears an error and the orb says so.
    if phase.setupBlocker != nil {
      publish(.error(message: "Blurt needs an API key. Open Blurt to add one."), reason: .noKey)
    } else {
      publish(overlay, reason: reason(for: phase))
    }
    note(overlay)
    if phase.isTerminal { dictationEnded(phase) }
  }

  private func observeLevels() -> Task<Void, Never> {
    let levels = window.source.levels
    return Task { [weak self] in
      for await value in levels {
        guard let self else {
          return
        }
        // Only while recording: the feed reports levels only for an open
        // utterance, and the home screen's hero shouldn't redraw for a
        // window sitting idle in the background.
        guard phase == .recording else { continue }
        level = value
        // The keyboard redraws its meter from these; ~12 Hz is plenty for a pill
        // and keeps the shared-defaults writes off the capture path's back.
        guard sinceLevelPublish() > .milliseconds(80) else { continue }
        sinceLevelPublish = Self.stopwatch(on: clock)
        publish(.recording)
      }
    }
  }

  private func observeRecents() -> Task<Void, Never> {
    let recentStream = recents
    return Task { [weak self] in
      for await ring in recentStream {
        guard let self else {
          return
        }
        recent = ring
      }
    }
  }

  // MARK: - The home card's error

  /// A failed dictation, said on the home card for `HomeStatus.errorDwell`.
  private func note(_ overlay: OverlayUIState) {
    guard case .error(let message, _) = overlay else {
      return
    }
    error = message
    errorDwell?.cancel()
    errorDwell = Task { [weak self] in
      try? await Task.sleep(for: .seconds(HomeStatus.errorDwell))
      guard !Task.isCancelled else {
        return
      }
      self?.error = nil
    }
  }

  /// The window's state changed: a headline about a failure never outlives
  /// the session it happened in.
  private func clearError() {
    errorDwell?.cancel()
    errorDwell = nil
    error = nil
  }

  deinit {
    watchdog?.cancel()
    errorDwell?.cancel()
    returnCap?.cancel()
    for task in tasks { task.cancel() }
  }
}
