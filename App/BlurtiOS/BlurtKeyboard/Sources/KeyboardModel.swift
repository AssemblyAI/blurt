import BlurtEngine
import Foundation
import Observation
import UIKit

/// The keyboard's state and its side of the conversation with the app: it
/// sends press / release / cancel with the text around the cursor, shows the
/// phase the app publishes, and inserts the words that come back.
///
/// The mic key's tap-versus-hold rule is the engine's own `DictationKeyGate`,
/// driven by the finger instead of a modifier key: finger down is the key going
/// down, finger up the key coming up, so a tap latches and a hold is
/// push-to-talk exactly as on the Mac.
@MainActor
@Observable
final class KeyboardModel {
  /// How old a result may be and still be inserted. Darwin notifications are
  /// held for a suspended process and delivered when it resumes, so the
  /// keyboard inside the app the user *left* hears about a dictation done
  /// elsewhere minutes later; anything older than this is not its to insert.
  static let resultFreshnessWindow: TimeInterval = 10
  /// The phone's word list is re-read at most this often. Contacts change by
  /// the day, and reading thousands of them on every appearance is what the
  /// keyboard's memory budget cannot afford.
  static let lexiconRefreshInterval: TimeInterval = 60 * 60

  var layout: KeyboardLayout = .panel
  /// The panel is a two-page carousel — the mic panel and the full keyboard —
  /// flipped by a swipe in either direction, as often as you like. Which page
  /// is up; back to the mic each time the keyboard appears.
  var panelShowsKeys = false
  /// The direction of the last flip, so the pages slide the way the finger went.
  var flipTowardsLeading = false
  var snapshot = PhaseSnapshot.idle
  var isListening = false
  var hasFullAccess = false
  var needsGlobe = true
  var shifted = true
  var symbolsPage = false

  @ObservationIgnored private weak var controller: UIInputViewController?
  @ObservationIgnored private var observers: [DarwinObserver] = []
  @ObservationIgnored private var gate = DictationKeyGate()
  @ObservationIgnored private let clockStart = ContinuousClock.now
  @ObservationIgnored private var lastResultID: UUID?
  @ObservationIgnored private var heartbeat: Task<Void, Never>?
  @ObservationIgnored private var lastSpaceAt: ContinuousClock.Instant?
  @ObservationIgnored private var noticeDwell: Task<Void, Never>?

  var proxy: (any UITextDocumentProxy)? { controller?.textDocumentProxy }

  /// One palette for now; themes are a later feature.
  var palette: KeyboardPalette { .blurt }

  /// What is actually on screen: the panel's carousel may be showing its keys.
  var effectiveLayout: KeyboardLayout { layout == .panel && panelShowsKeys ? .full : layout }

  /// Told when `effectiveLayout` changes, so the host can resize the keyboard.
  @ObservationIgnored var onLayoutChange: (() -> Void)?

  /// A horizontal swipe on the panel: flip to the other page, sliding the way
  /// the finger went.
  func flipPanel(towardsLeading: Bool) {
    guard layout == .panel else { return }
    flipTowardsLeading = towardsLeading
    panelShowsKeys.toggle()
    onLayoutChange?()
  }

  /// Whether the phase leaves nothing in flight — the moments the gate has to
  /// be reset, since a dictation can end with no finger event to close it.
  private var isSettled: Bool {
    switch snapshot.state {
    case .idle, .pasted, .copied, .error: true
    case .connecting, .recording, .processing: false
    }
  }

  // MARK: - Lifecycle

  func attach(to controller: UIInputViewController) {
    self.controller = controller
    observers = [
      DarwinObserver(name: BlurtShared.Signal.phase) { [weak self] in
        Task { @MainActor in self?.phaseChanged() }
      },
      DarwinObserver(name: BlurtShared.Signal.result) { [weak self] in
        Task { @MainActor in self?.resultArrived() }
      },
    ]
  }

  func appeared() {
    hasFullAccess = controller?.hasFullAccess ?? false
    needsGlobe = controller?.needsInputModeSwitchKey ?? true
    updateShift()
    // Without Full Access the App Group is out of reach: the keyboard still
    // types, and says what it needs (see `KeyboardRootView`), but nothing below
    // can run.
    guard hasFullAccess else { return }
    layout = SharedStore.layout
    panelShowsKeys = false
    SharedStore.keyboardEverSeen = true
    refresh()
    startHeartbeat()
    requestLexicon()
    if SharedStore.autoDictate { autoStart() }
  }

  /// Hands-free: a dictation begins the moment the keyboard is up, as if the
  /// mic had been tapped — the same synthetic tap through the engine's gate,
  /// so it latches and the next real tap stops it. Only when the app is
  /// listening and nothing is in flight; otherwise the pill says what to do.
  private func autoStart() {
    guard isListening, isSettled, gate.isIdle else { return }
    perform(gate.modifierDown(at: elapsed))
    perform(gate.modifierUp(at: elapsed))
  }

  func disappeared() {
    heartbeat?.cancel()
    heartbeat = nil
    // Presence means on screen. A dictation that finishes after the keyboard
    // is gone goes to the clipboard, not to a keyboard nobody can see.
    SharedStore.keyboardSeenAt = nil
  }

  /// The cursor moved or the text around it changed, including by our own
  /// typing: re-read where the sentence stands.
  func contextChanged() {
    updateShift()
  }

  /// Auto-capitalisation, as the system keyboard does it: shift comes on at
  /// the start of a sentence (or of every word, or always) according to what
  /// the field asks for, and goes off after one letter.
  private func updateShift() {
    guard let proxy else { return }
    let before = proxy.documentContextBeforeInput ?? ""
    switch proxy.autocapitalizationType ?? .sentences {
    case .none: break
    case .allCharacters: shifted = true
    case .words: shifted = before.isEmpty || before.last?.isWhitespace == true
    case .sentences: shifted = Self.isSentenceStart(before)
    @unknown default: break
    }
  }

  private static func isSentenceStart(_ before: String) -> Bool {
    let trimmed = before.reversed().drop { $0 == " " }
    guard let last = trimmed.first else { return true }
    return last == "\n" || ".?!".contains(last)
  }

  private func refresh() {
    isListening = SharedStore.isListening
    if let current = SharedStore.read(PhaseSnapshot.self, forKey: BlurtShared.Key.phase) {
      apply(current.isStale ? .idle : current)
    }
  }

  /// Tells the app the keyboard is on screen, so a finished dictation is
  /// handed here rather than copied to the clipboard.
  private func startHeartbeat() {
    heartbeat?.cancel()
    heartbeat = Task { [weak self] in
      while !Task.isCancelled {
        SharedStore.keyboardSeenAt = Date()
        self?.isListening = SharedStore.isListening
        try? await Task.sleep(for: .seconds(4))
      }
    }
  }

  /// The phone's own word list — contact names and text replacements — for
  /// the app to spell names right with no setup. Read here because only the
  /// keyboard is offered it; the app reads it back out of the App Group.
  private func requestLexicon() {
    let refreshed = SharedStore.lexiconRefreshedAt ?? .distantPast
    guard Date().timeIntervalSince(refreshed) > Self.lexiconRefreshInterval else { return }
    // UIKit calls back on an XPC queue, not the main thread (a main-actor
    // closure here traps), while the lexicon's entries are main-actor in
    // Swift's eyes. So: take the callback anywhere, hand the immutable lexicon
    // over, and read it on the main actor.
    controller?.requestSupplementaryLexicon { @Sendable lexicon in
      let handoff = LexiconHandoff(lexicon)
      Task { @MainActor in Self.store(handoff.lexicon) }
    }
  }

  private nonisolated struct LexiconHandoff: @unchecked Sendable {
    let lexicon: UILexicon
    init(_ lexicon: UILexicon) { self.lexicon = lexicon }
  }

  private static func store(_ lexicon: UILexicon) {
    let entries = lexicon.entries.map {
      LexiconEntry(userInput: $0.userInput, documentText: $0.documentText)
    }
    SharedStore.write(entries, forKey: BlurtShared.Key.lexicon)
    SharedStore.lexiconRefreshedAt = Date()
    SharedStore.post(BlurtShared.Signal.lexicon)
  }

  // MARK: - The mic key

  func micDown() {
    // No Full Access, or the app isn't listening: the mic key's job is to get
    // the user to the app, whose checklist says what is missing. Opening the
    // app needs no Full Access; everything else here does.
    guard hasFullAccess, isListening else {
      openApp()
      return
    }
    perform(gate.modifierDown(at: elapsed))
  }

  func micUp() {
    guard hasFullAccess, isListening else { return }
    perform(gate.modifierUp(at: elapsed))
  }

  func cancel() {
    gate.reset()
    send(.cancel)
  }

  private var elapsed: Duration { clockStart.duration(to: ContinuousClock.now) }

  private func perform(_ action: DictationKeyGate.Action) {
    switch action {
    case .start: send(.press)
    case .stop: send(.release)
    case .cancel: send(.cancel)
    case .none: break
    }
  }

  private func send(_ kind: KeyboardCommand.Kind) {
    let command = KeyboardCommand(
      id: UUID(), kind: kind, priorText: proxy?.documentContextBeforeInput,
      selectedText: proxy?.selectedText, sentAt: Date())
    SharedStore.write(command, forKey: BlurtShared.Key.command)
    SharedStore.post(BlurtShared.Signal.command)
  }

  // MARK: - What comes back

  private func phaseChanged() {
    guard let current = SharedStore.read(PhaseSnapshot.self, forKey: BlurtShared.Key.phase) else { return }
    apply(current.isStale ? .idle : current)
  }

  private func apply(_ current: PhaseSnapshot) {
    let previous = snapshot.state
    snapshot = current
    isListening = SharedStore.isListening
    if current.state != previous { haptics(from: previous, to: current.state) }
    // A dictation that ended without a finger event (auto-release, an error)
    // would leave the gate latched and swallow the next tap — the same sync the
    // Mac shell does on every terminal phase.
    if isSettled, !gate.isIdle { gate.reset() }
    // A notice is over after its dwell: the Mac pill fades out, this one goes
    // back to saying how to start.
    noticeDwell?.cancel()
    if let seconds = current.noticeDwellSeconds {
      noticeDwell = Task { [weak self] in
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return }
        self?.apply(.idle)
      }
    }
  }

  private func resultArrived() {
    guard let result = SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result),
      result.id != lastResultID, let proxy,
      Date().timeIntervalSince(result.deliveredAt) < Self.resultFreshnessWindow
    else { return }
    lastResultID = result.id
    // Taken out of the store once inserted, so no other keyboard process —
    // each host app runs its own — can insert the same words again.
    SharedStore.remove(forKey: BlurtShared.Key.result)
    // Joined against the live text before the cursor, not the press-time
    // snapshot: the user may have typed since.
    proxy.insertText(InsertionSeparator.withLeadingSeparator(result.text, after: proxy.documentContextBeforeInput))
  }

  private func haptics(from previous: PhaseSnapshot.State, to state: PhaseSnapshot.State) {
    guard hasFullAccess else { return }
    switch state {
    case .recording:
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    case .processing where previous == .recording:
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    case .pasted, .copied:
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    case .error:
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    case .idle, .connecting, .processing:
      break
    }
  }
}

// MARK: - Typing and the app

extension KeyboardModel {
  func type(_ text: String) {
    proxy?.insertText(text)
    if shifted, !symbolsPage { shifted = false }
  }

  func deleteBackward() { proxy?.deleteBackward() }

  func newline() { proxy?.insertText("\n") }

  /// A space — or, tapped twice quickly after a word, the system keyboard's
  /// "." shortcut: the first space becomes a full stop and a space.
  func space() {
    let now = ContinuousClock.now
    let before = proxy?.documentContextBeforeInput ?? ""
    if let last = lastSpaceAt, now - last < .milliseconds(450), before.hasSuffix(" "), !before.hasSuffix("  "),
      let previous = before.dropLast().last, previous.isLetter || previous.isNumber
    {
      proxy?.deleteBackward()
      proxy?.insertText(". ")
      lastSpaceAt = nil
    } else {
      proxy?.insertText(" ")
      lastSpaceAt = now
    }
    updateShift()
  }

  func toggleShift() { shifted.toggle() }

  func toggleSymbols() { symbolsPage.toggle() }

  func globe() { controller?.advanceToNextInputMode() }

  /// Brings the app forward to open the microphone — the one thing a keyboard
  /// cannot do for itself. iOS gives extensions no `open(_:)`, so this walks the
  /// responder chain to the application object and asks it, the way every
  /// keyboard that opens its app does.
  func openApp() {
    guard let controller,
      let url = URL(string: "\(BlurtShared.urlScheme)://\(BlurtShared.startHost)")
    else { return }
    let selector = sel_registerName("openURL:")
    var responder: UIResponder? = controller
    while let current = responder {
      if current.responds(to: selector) {
        _ = current.perform(selector, with: url)
        return
      }
      responder = current.next
    }
  }
}
