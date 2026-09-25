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
  /// The key term being typed on the keys, while the voice bar is a field;
  /// nil otherwise. See `beginAddingTerm`.
  var termDraft: String?
  /// When the last term was saved, so the bar can show a check for a moment.
  var termSavedAt: Date?
  /// The field's own return key, as iOS labels it: "send", "search", "go"…
  var returnLabel: String?
  /// The letter rows for the user's first keyboard language (AZERTY for
  /// French, QWERTZ for German and its neighbours, QWERTY otherwise).
  var letterRows = LetterLayout.qwerty
  var isListening = false
  var hasFullAccess = false
  var needsGlobe = true
  var shifted = true
  var symbolsPage = false

  // Internal, not private: the typing half of this model lives in
  // KeyboardModel+Typing.swift.
  @ObservationIgnored weak var controller: UIInputViewController?
  @ObservationIgnored private var observers: [DarwinObserver] = []
  @ObservationIgnored private var gate = DictationKeyGate()
  @ObservationIgnored private let clockStart = ContinuousClock.now
  @ObservationIgnored private var lastResultID: UUID?
  @ObservationIgnored private var heartbeat: Task<Void, Never>?
  @ObservationIgnored var lastSpaceAt: ContinuousClock.Instant?
  @ObservationIgnored private var noticeDwell: Task<Void, Never>?
  @ObservationIgnored var termDraftFromSelection: String?
  /// The text before the cursor when the term field opened, so typing that
  /// reaches the host field anyway (a hardware keyboard: an iPad's, a
  /// Bluetooth one, the simulator's Mac) can be pulled into the term instead.
  @ObservationIgnored var termHostBaseline: String?
  @ObservationIgnored var termNotice: Task<Void, Never>?

  /// The host's text field. Tests hand in a fake in place of a controller.
  var proxy: (any UITextDocumentProxy)? { proxyOverride ?? controller?.textDocumentProxy }
  @ObservationIgnored var proxyOverride: (any UITextDocumentProxy)?

  /// The chosen theme's palette — or, for a preview, whatever it is told.
  var palette: KeyboardPalette { paletteOverride ?? .named(themeID) }
  var themeID = SharedStore.themeID
  var paletteOverride: KeyboardPalette?

  /// What is actually on screen: the panel's carousel may be showing its
  /// keys, and typing a key term needs them whatever the layout.
  var effectiveLayout: KeyboardLayout {
    if termDraft != nil { return .full }
    return layout == .panel && panelShowsKeys ? .full : layout
  }

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
    letterRows = LetterLayout.forPreferredLanguages()
    readField()
    updateShift()
    // Without Full Access the App Group is out of reach: the keyboard still
    // types, and says what it needs (see `KeyboardRootView`), but nothing below
    // can run.
    guard hasFullAccess else { return }
    layout = SharedStore.layout
    themeID = SharedStore.themeID
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
  /// typing: re-read where the sentence stands and what the field wants.
  func contextChanged() {
    readField()
    claimHostTypingForTerm()
    updateShift()
  }

  /// While the term field is open, characters that arrived in the host field
  /// (a hardware keyboard types past the on-screen keys) belong to the term:
  /// move them over and take them back out of the field. Only a short,
  /// appended run right after where the cursor was; anything else is left.
  private func claimHostTypingForTerm() {
    guard termDraft != nil, let baseline = termHostBaseline, let proxy else { return }
    let now = proxy.documentContextBeforeInput ?? ""
    let delta = now.count - baseline.count
    guard delta > 0, delta <= 8, now.dropLast(delta).hasSuffix(baseline.suffix(24)) else { return }
    let typed = String(now.suffix(delta))
    for _ in 0..<delta { proxy.deleteBackward() }
    termDraft?.append(typed)
  }

  /// What the field asked for, the way the system keyboard honours it: the
  /// return key's own word, and the symbols page first for a number field.
  private func readField() {
    returnLabel = proxy?.returnKeyType.flatMap(Self.returnLabel)
    switch proxy?.keyboardType {
    case .numberPad, .decimalPad, .phonePad, .numbersAndPunctuation, .asciiCapableNumberPad: symbolsPage = true
    default: break
    }
  }

  /// iOS's own words for the return key, by the type the field asked for.
  private static let returnLabels: [UIReturnKeyType: String] = [
    .go: "go", .google: "search", .yahoo: "search", .search: "search", .join: "join", .next: "next",
    .route: "route", .send: "send", .done: "done", .emergencyCall: "call", .continue: "continue",
  ]

  private static func returnLabel(_ type: UIReturnKeyType) -> String? { returnLabels[type] }

  /// Auto-capitalisation, as the system keyboard does it: shift comes on at
  /// the start of a sentence (or of every word, or always) according to what
  /// the field asks for, and goes off after one letter.
  func updateShift() {
    if let termDraft {
      // A key term is usually a name: capitalised to start, then as typed.
      shifted = termDraft.isEmpty
      return
    }
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

  static func isSentenceStart(_ before: String) -> Bool {
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
