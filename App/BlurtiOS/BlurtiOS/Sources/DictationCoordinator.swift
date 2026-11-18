import AssemblyAI
import BlurtEngine
import BlurtiOSCore
import Foundation
import Observation
import Synchronization
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
  /// leave; nil reads the window's idle mode (a test sets it).
  @ObservationIgnored var expectsKeeper: Bool?
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
  @ObservationIgnored private var lastLevelPublish = ContinuousClock.now

  /// Who pressed last and what their field held, until the session accepts
  /// the press (`claimPress`). A press the session refuses — one arriving while
  /// a dictation is still in flight — must not take over that dictation's words.
  nonisolated struct Press: Sendable {
    var keyboard: String?
    var context = FocusedFieldContext.empty
    /// The keyboard whose accepted stop ended the dictation, which is where
    /// the words go. The dictation itself and its owner are `inFlight`.
    var stopRecipient: String?
  }
  nonisolated static let pendingPress = Mutex(Press())
  /// The press that started the dictation in flight: its keyboard, for the
  /// words to go back to, and what that keyboard saw around the cursor, read
  /// by the engine's context seam — and cleared once used, so nothing from
  /// another app's field primes a later request.
  nonisolated static let claimedPress = Mutex(Press())
  /// Contact names, parsed once per lexicon refresh rather than on the press.
  nonisolated private static let lexiconNames = Mutex<[String]>([])
  /// The words the session just delivered, waiting to be counted. The stats are
  /// recorded on the main actor when the dictation's terminal phase renders —
  /// after its recording has been timed, and in the same place a reset runs —
  /// rather than on the session's actor, where neither ordering holds.
  nonisolated private static let deliveredText = Mutex<String?>(nil)
  /// When the recording in progress started (the keyboard's countdown reads
  /// it off the phase), and how long the last one ran.
  @ObservationIgnored private(set) var recordingSince: Date?
  @ObservationIgnored private var lastSpokenSeconds: Double = 0

  /// `transcriber` and `clock` are seams for the tests, which drive a press
  /// through the real session against a stub transcript and a clock they
  /// advance; the app keeps both defaults.
  /// Whether the app is in front, as `handle(url)` reads it; a test's stand-in.
  @ObservationIgnored let appState: @MainActor () -> UIApplication.State
  /// Brings the host app back (`HostReturn.open`); a test's capture.
  @ObservationIgnored let hostReturner: @MainActor (String) -> Bool

  init(
    apiKey: APIKeyModel = APIKeyModel(), window: ListeningWindow = ListeningWindow(),
    transcriber: any TranscriberProtocol = AssemblyAITranscriber(), clock: any Clock<Duration> = ContinuousClock(),
    appState: @escaping @MainActor () -> UIApplication.State = { UIApplication.shared.applicationState },
    hostReturner: @escaping @MainActor (String) -> Bool = HostReturn.open(bundleID:)
  ) {
    self.window = window
    self.apiKey = apiKey
    self.clock = clock
    self.appState = appState
    self.hostReturner = hostReturner
    let (recents, continuation) = AsyncStream.makeStream(
      of: RecentDictations.self, bufferingPolicy: .bufferingNewest(1))
    self.recents = recents
    session = DictationSession(
      mic: window.source,
      transcriber: transcriber,
      // The words go to the keyboard that sent the accepted stop, else to
      // the one whose press started the dictation.
      injector: KeyboardRelayInjector(presser: { Self.claimedPress.withLock { $0.stopRecipient ?? $0.keyboard } }),
      keyTermsProvider: { Self.keyTerms() },
      readinessCheck: apiKey.readinessCheck(),
      onTranscriptDelivered: { text, ring in
        Self.deliveredText.withLock { $0 = text }
        continuation.yield(ring)
      },
      // The keyboard is the only thing that can see the field: the press
      // command carries the text before the cursor, and that is what primes
      // the request — the same signal the Mac reads through Accessibility.
      // `frontmost` runs only for a press the session accepts, first thing, so
      // that is where the press's keyboard and field text become the dictation's.
      hostFocusCapture: DictationSession.HostFocusCapture(
        frontmost: { Self.claimPress() }, field: { Self.fieldContext() }))
    window.onEndingUtterance = { [weak self] keepWords in await self?.endUtterance(keepWords: keepWords) }
    window.onStateChanged = { [weak self] _ in self?.clearError() }
    window.onRecord = { [weak self] record in self?.recordPublished(record) }
  }

  deinit {
    watchdog?.cancel()
    errorDwell?.cancel()
    returnCap?.cancel()
    for task in tasks { task.cancel() }
  }

  func start() {
    // `.task` on the root view runs this once; a scene reconnect must not
    // start a second set of observers publishing every phase twice.
    guard tasks.isEmpty else { return }
    // Whatever the last run left in the App Group is over: a fresh launch,
    // no window, and the phase idle under it. The window's heartbeat runs
    // from here for as long as the process does.
    window.start()
    observers = [
      DarwinObserver(name: BlurtShared.Signal.command) { [weak self] in
        Task { @MainActor in self?.handleCommand() }
      },
      DarwinObserver(name: BlurtShared.Signal.keyboard) { [weak self] in
        Task { @MainActor in self?.tickWatchdog() }
      },
      DarwinObserver(name: BlurtShared.Signal.lexicon) { [weak self] in
        Task { @MainActor in self?.reloadLexicon() }
      },
    ]
    reloadLexicon()
    tasks = [observePhases(), observeLevels(), observeRecents()]
    publish(.idle)
  }

  // MARK: - Key terms

  private func reloadLexicon() {
    let entries = SharedStore.read([LexiconEntry].self, forKey: BlurtShared.Key.lexicon) ?? []
    let names = entries.filter(\.isName).map(\.documentText)
    Self.lexiconNames.withLock { $0 = names }
    lexiconNameCount = names.count
  }

  /// The user's own key terms (from the App Group, where the keyboard adds
  /// them on the spot), then the contact names the keyboard read off the
  /// phone, deduplicated case-insensitively. `KeyTerms` fits the list
  /// to the request's caps (100 terms, 2048 bytes), first entries first, which
  /// is why the typed terms lead.
  nonisolated static func keyTerms() -> [String] {
    // Not through the comma-separated form: a contact called "Smith, John"
    // is one name, and the engine takes an array.
    KeyTerms.normalized(SharedStore.keyTerms + lexiconNames.withLock { $0 })
  }

  // MARK: - Phase, level and results out to the keyboard

  private func observePhases() -> Task<Void, Never> {
    let session = session
    return Task { [weak self] in
      for await phase in await session.phaseStream() {
        guard let self else { return }
        self.render(phase)
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
        recordingSince = Date()
        window.utteranceStarted()
      }
    } else if utteranceOpen {
      // The recording is over; how long it ran is kept for the stats.
      utteranceOpen = false
      if let since = recordingSince { lastSpokenSeconds = Date().timeIntervalSince(since) }
      window.utteranceEnded()
    }
    if phase.isTerminal { recordingSince = nil }
    // Delivery always comes before the paste and its terminal phase, and the
    // phases render in order, so the dictation's words are waiting by now.
    if phase.isTerminal,
      let text = Self.deliveredText.withLock({ text in
        defer { text = nil }
        return text
      })
    {
      DictationStats.record(text, spokenFor: lastSpokenSeconds)
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
        guard let self else { return }
        // Only while recording: the feed reports levels only for an open
        // utterance, and the home screen's hero shouldn't redraw for a
        // window sitting idle in the background.
        guard self.phase == .recording else { continue }
        self.level = value
        // The keyboard redraws its meter from these; ~12 Hz is plenty for a pill
        // and keeps the shared-defaults writes off the capture path's back.
        guard self.lastLevelPublish.duration(to: ContinuousClock.now) > .milliseconds(80) else { continue }
        self.lastLevelPublish = ContinuousClock.now
        self.publish(.recording)
      }
    }
  }

  private func observeRecents() -> Task<Void, Never> {
    let recents = recents
    return Task { [weak self] in
      for await ring in recents {
        guard let self else { return }
        self.recent = ring
      }
    }
  }

  /// The phase as the home screen and the keyboard show it: the engine's own
  /// wording, except a capture failure, which is said as the source's own
  /// sentence (`CaptureFailure`) rather than as "Audio capture failed: …".
  var overlay: OverlayUIState {
    if case .failed(.audioCaptureFailed(let underlying)) = phase {
      return .error(message: CaptureFailure.sentence(for: underlying))
    }
    return phase.overlayState
  }

  /// Why the phase is an error, typed, for the keyboard's line: a capture
  /// failure's reason; nothing for a failure the engine words itself.
  private func reason(for phase: PipelinePhase) -> FailureReason? {
    guard case .failed(.audioCaptureFailed(let underlying)) = phase else { return nil }
    return CaptureFailure.reason(for: underlying)
  }

  private func publish(_ state: OverlayUIState, reason: FailureReason? = nil) {
    let snapshot = PhaseSnapshot(
      state: PhaseSnapshot.State(state), message: PhaseSnapshot.message(for: state), level: Double(level),
      at: Date(), command: lastCommandID, reason: reason, answers: answers, dictation: inFlight,
      launchID: window.launchID, recordingSince: recordingSince)
    SharedStore.write(snapshot, forKey: BlurtShared.Key.phase)
    SharedStore.post(BlurtShared.Signal.phase)
  }

  // MARK: - The home card's error

  /// A failed dictation, said on the home card for `HomeStatus.errorDwell`.
  private func note(_ overlay: OverlayUIState) {
    guard case .error(let message, _) = overlay else { return }
    error = message
    errorDwell?.cancel()
    errorDwell = Task { [weak self] in
      try? await Task.sleep(for: .seconds(HomeStatus.errorDwell))
      guard !Task.isCancelled else { return }
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
}
