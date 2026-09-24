import AVFoundation
import BlurtEngine
import Foundation
import Observation

/// The one place the engine is composed for the iPhone app — the role
/// `AppCoordinator` plays in the Mac shell. It owns the listening window (the
/// microphone), the session, and the two channels to the keyboard: commands
/// coming in over the App Group, phase and results going back out.
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

  @ObservationIgnored private let session: DictationSession
  @ObservationIgnored private let recents: AsyncStream<RecentDictations>
  @ObservationIgnored private var observers: [DarwinObserver] = []
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var lastCommandID: UUID?
  @ObservationIgnored private var lastLevelPublish = ContinuousClock.now

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
      injector: KeyboardRelayInjector(),
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
    observers = [
      DarwinObserver(name: BlurtShared.Signal.command) {
        Task { @MainActor [weak self] in self?.handleCommand() }
      },
      DarwinObserver(name: BlurtShared.Signal.lexicon) {
        Task { @MainActor [weak self] in self?.reloadLexicon() }
      },
    ]
    reloadLexicon()
    tasks = [observePhases(), observeLevels(), observeRecents()]
  }

  // MARK: - The listening window

  /// Opens the microphone for the keyboard. Foreground only — this is what
  /// `blurt://start` arrives to do.
  func startListening() async {
    guard await AVAudioApplication.requestRecordPermission() else {
      microphoneDenied = true
      return
    }
    microphoneDenied = false
    window.open()
  }

  func stopListening() {
    if phase.isCapturing { session.submit(.cancel) }
    window.close()
    publish(.idle)
  }

  func handle(_ url: URL) {
    guard url.scheme == BlurtShared.urlScheme, url.host() == BlurtShared.startHost else { return }
    Task { await startListening() }
  }

  /// A dictation started from the app itself, with no keyboard to land in —
  /// the words go to the clipboard. The way to try Blurt before the keyboard is
  /// set up, and the way to test the pipeline without one.
  func toggleDictation() {
    session.submit(phase.isCapturing ? .release : .press)
  }

  // MARK: - Commands from the keyboard

  private func handleCommand() {
    guard let command = SharedStore.read(KeyboardCommand.self, forKey: BlurtShared.Key.command),
      command.id != lastCommandID
    else { return }
    lastCommandID = command.id
    switch command.kind {
    case .press: session.submit(.press)
    case .release: session.submit(.release)
    case .cancel: session.submit(.cancel)
    }
  }

  private func reloadLexicon() {
    let entries = SharedStore.read([LexiconEntry].self, forKey: BlurtShared.Key.lexicon) ?? []
    lexiconNameCount = entries.filter(\.isName).count
  }

  /// The user's typed key terms, then the contact names the keyboard read off
  /// the phone, deduplicated case-insensitively. `KeytermsBoost` fits the list
  /// to the request's caps (100 terms, 2048 bytes), first entries first, which
  /// is why the typed terms lead.
  nonisolated static func keyTerms() -> [String] {
    let typed = UserDefaults.standard.string(forKey: KeyTermsStore.defaultsKey) ?? ""
    let names = (SharedStore.read([LexiconEntry].self, forKey: BlurtShared.Key.lexicon) ?? [])
      .filter(\.isName).map(\.documentText)
    let candidates = typed.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    var seen = Set<String>()
    var terms: [String] = []
    for term in candidates + names where !term.isEmpty && seen.insert(term.lowercased()).inserted {
      terms.append(term)
    }
    return terms
  }

  /// What the keyboard saw around the cursor when it sent the press.
  nonisolated static func fieldContext() -> FocusedFieldContext {
    guard let command = SharedStore.read(KeyboardCommand.self, forKey: BlurtShared.Key.command),
      command.kind == .press
    else { return .empty }
    return FocusedFieldContext(
      priorText: command.priorText, selectedText: command.selectedText, windowTitle: nil, fieldLabel: nil)
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
    publish(phase.overlayState)
  }

  private func observeLevels() -> Task<Void, Never> {
    let levels = window.source.levels
    return Task { [weak self] in
      for await value in levels {
        guard let self else { return }
        self.level = value
        // The keyboard redraws its meter from these; ~12 Hz is plenty for a pill
        // and keeps the shared-defaults writes off the capture path's back.
        guard self.phase == .recording,
          self.lastLevelPublish.duration(to: ContinuousClock.now) > .milliseconds(80)
        else { continue }
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
      state: Self.snapshotState(state), message: Self.message(state), level: Double(level), at: Date())
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
