import AVFoundation
import BlurtEngine
import BlurtiOSCore
import Foundation
import Observation
import Synchronization

/// The one place the engine is composed for the iPhone app — the role
/// `AppCoordinator` plays in the Mac shell. It owns the listening window (the
/// microphone), the session, and the two channels to the keyboard: commands
/// coming in over the App Group, phase and results going back out.
///
/// Key terms live in the App Group (`SharedStore.keyTerms`) rather than the
/// engine's `KeyTermsStore` (which reads the process's own defaults), so the
/// keyboard can add one on the spot; `keyTermsProvider` is how they reach the
/// request.
@MainActor
@Observable
final class DictationCoordinator {
  let window: ListeningWindow
  let apiKey: APIKeyModel
  private(set) var phase: PipelinePhase = .idle
  private(set) var recent = RecentDictations()
  private(set) var level: Float = 0
  private(set) var microphoneDenied = false
  /// How many contact names the keyboard last read off the phone — the key
  /// terms that come for free, so the home screen can say so.
  private(set) var lexiconNameCount = 0
  /// A shared key-term list the app was asked to open, until the user has
  /// answered it (`ImportTermsView`).
  var pendingTermPack: TermPack?
  /// A file or link that claimed to be a key-term list and wasn't.
  var termPackUnreadable = false
  /// The window can't open without a key: the last "Start listening" said so.
  var needsKey = false

  @ObservationIgnored private let session: DictationSession
  @ObservationIgnored private let recents: AsyncStream<RecentDictations>
  @ObservationIgnored private var observers: [DarwinObserver] = []
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var lastCommandID: UUID?
  @ObservationIgnored private var lastLevelPublish = ContinuousClock.now

  /// What the keyboard saw around the cursor on the press that started the
  /// dictation in flight, read by the engine's context seam — and cleared once
  /// used, so nothing from another app's field primes a later request.
  nonisolated private static let pressContext = Mutex<FocusedFieldContext>(.empty)
  /// The keyboard process that pressed, for the words to go back to it.
  nonisolated private static let pressKeyboard = Mutex<String?>(nil)
  /// Contact names, parsed once per lexicon refresh rather than on the press.
  nonisolated private static let lexiconNames = Mutex<[String]>([])

  init(apiKey: APIKeyModel = APIKeyModel()) {
    let window = ListeningWindow()
    self.window = window
    self.apiKey = apiKey
    let (recents, continuation) = AsyncStream.makeStream(
      of: RecentDictations.self, bufferingPolicy: .bufferingNewest(1))
    self.recents = recents
    session = DictationSession(
      mic: window.source,
      transcriber: AssemblyAITranscriber(),
      injector: KeyboardRelayInjector(presser: { Self.pressKeyboard.withLock { $0 } }),
      keyTermsProvider: { Self.keyTerms() },
      readinessCheck: apiKey.readinessCheck(),
      onTranscriptDelivered: { _, ring in continuation.yield(ring) },
      // The keyboard is the only thing that can see the field: the press
      // command carries the text before the cursor, and that is what primes
      // the request — the same signal the Mac reads through Accessibility.
      hostFocusCapture: DictationSession.HostFocusCapture(
        frontmost: { nil }, field: { Self.fieldContext() }))
  }

  func start() {
    // `.task` on the root view runs this once; a scene reconnect must not
    // start a second set of observers publishing every phase twice.
    guard tasks.isEmpty else { return }
    observers = [
      DarwinObserver(name: BlurtShared.Signal.command) { [weak self] in
        Task { @MainActor in self?.handleCommand() }
      },
      DarwinObserver(name: BlurtShared.Signal.lexicon) { [weak self] in
        Task { @MainActor in self?.reloadLexicon() }
      },
    ]
    reloadLexicon()
    tasks = [observePhases(), observeLevels(), observeRecents()]
    // Whatever the last run left in the App Group is over.
    publish(.idle)
  }

  // MARK: - The listening window

  /// Opens the microphone for the keyboard. Foreground only — this is what
  /// `blurt://start` arrives to do. Not without a key: an open window whose
  /// every press fails quietly would look like a keyboard that ignores taps.
  func startListening() async {
    apiKey.refreshStatus()
    needsKey = !apiKey.hasAPIKey
    guard !needsKey else { return }
    guard await AVAudioApplication.requestRecordPermission() else {
      microphoneDenied = true
      return
    }
    microphoneDenied = false
    await window.open()
  }

  /// Closes the window. A dictation in flight is cancelled first, upload and
  /// all — closing the feed alone would end the utterance and let the request
  /// complete, transcribing (and billing) audio nobody asked for.
  func stopListening() async {
    if !phase.isTerminal { await session.cancel() }
    await window.close()
    publish(.idle)
  }

  func handle(_ url: URL) {
    if TermPack.looksLikePack(url) {
      if let pack = TermPack.from(url) {
        pendingTermPack = pack
      } else {
        termPackUnreadable = true
      }
      return
    }
    guard url.scheme == BlurtShared.urlScheme, url.host() == BlurtShared.startHost else { return }
    Task { await startListening() }
  }

  /// A dictation started from the app itself, with no keyboard to land in —
  /// the words go to the clipboard. The way to try Blurt before the keyboard is
  /// set up, and the way to test the pipeline without one. No field, so no
  /// prior text primes it.
  func toggleDictation() {
    Self.pressContext.withLock { $0 = .empty }
    Self.pressKeyboard.withLock { $0 = nil }
    session.submit(phase.isCapturing ? .release : .press)
  }

  // MARK: - Commands from the keyboard

  private func handleCommand() {
    guard let command = SharedStore.read(KeyboardCommand.self, forKey: BlurtShared.Key.command),
      command.id != lastCommandID
    else { return }
    lastCommandID = command.id
    // The command is consumed: nothing re-reads it, and the text it carried
    // from the user's field doesn't sit in the group container.
    SharedStore.remove(forKey: BlurtShared.Key.command)
    // A notification held while the app was suspended delivers a press from
    // minutes ago; the user has long since moved on.
    guard Date().timeIntervalSince(command.sentAt) < BlurtShared.commandFreshnessWindow else { return }
    switch command.kind {
    case .press:
      Self.pressContext.withLock {
        $0 = FocusedFieldContext(
          priorText: command.priorText, selectedText: command.selectedText, windowTitle: nil, fieldLabel: nil)
      }
      Self.pressKeyboard.withLock { $0 = command.keyboard }
      session.submit(.press)
    case .release: session.submit(.release)
    case .cancel: session.submit(.cancel)
    }
  }

  private func reloadLexicon() {
    let entries = SharedStore.read([LexiconEntry].self, forKey: BlurtShared.Key.lexicon) ?? []
    let names = entries.filter(\.isName).map(\.documentText)
    Self.lexiconNames.withLock { $0 = names }
    lexiconNameCount = names.count
  }

  /// The user's own key terms (from the App Group, where the keyboard adds
  /// them on the spot), then the contact names the keyboard read off the
  /// phone, deduplicated case-insensitively. `KeytermsBoost` fits the list
  /// to the request's caps (100 terms, 2048 bytes), first entries first, which
  /// is why the typed terms lead.
  nonisolated static func keyTerms() -> [String] {
    // Not through the comma-separated form: a contact called "Smith, John"
    // is one name, and the engine takes an array.
    var seen = Set<String>()
    var terms: [String] = []
    for term in SharedStore.keyTerms + lexiconNames.withLock({ $0 }) {
      let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
      terms.append(trimmed)
    }
    return terms
  }

  /// What the keyboard saw around the cursor on the press in flight, once.
  nonisolated static func fieldContext() -> FocusedFieldContext {
    pressContext.withLock { context in
      defer { context = .empty }
      return context
    }
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

  private func render(_ phase: PipelinePhase) {
    self.phase = phase
    if phase == .recording { window.extend() }
    // The Mac shows a setup blocker as calm idle beside a settings button;
    // the keyboard has no such button, so it hears an error and the orb says so.
    if phase.setupBlocker != nil {
      publish(.error(message: "Blurt needs an API key. Open Blurt to add one."))
      return
    }
    publish(phase.overlayState)
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

  private func publish(_ state: OverlayUIState) {
    let snapshot = PhaseSnapshot(
      state: Self.snapshotState(state), message: Self.message(state), level: Double(level), at: Date(),
      command: lastCommandID)
    SharedStore.write(snapshot, forKey: BlurtShared.Key.phase)
    SharedStore.post(BlurtShared.Signal.phase)
  }

  private static func snapshotState(_ state: OverlayUIState) -> PhaseSnapshot.State {
    switch state {
    case .idle: .idle
    case .connecting: .connecting
    case .recording: .recording
    case .processing: .processing
    case .pasted: .pasted
    case .noTarget: .copied
    case .error: .error
    }
  }

  private static func message(_ state: OverlayUIState) -> String? {
    guard case .error(let message) = state else { return nil }
    return message
  }
}
