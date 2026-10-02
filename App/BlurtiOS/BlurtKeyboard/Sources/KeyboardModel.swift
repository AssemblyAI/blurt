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
  /// When this keyboard last put the words into the field — the orb's drop.
  var resultLandedAt: Date?
  /// The key term being typed on the keys, while the voice bar is a field;
  /// nil otherwise. See `beginAddingTerm`.
  var termDraft: String?
  /// When the last term was saved, so the bar can show a check for a moment.
  var termSavedAt: Date?
  /// The word highlighted in the host's text, when it could be a key term
  /// (`termCandidate`) and the key terms are in reach (Full Access): the +
  /// grows into a chip holding it, and one tap adds it. Read off the proxy
  /// on every context change (`readSelection`); the gallery sets it.
  var selectedTerm: String?
  /// Whether `selectedTerm` is already one of Blurt's key terms: the chip
  /// shows a check and adds nothing.
  var selectedTermIsKnown = false
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
  /// The symbols' second page (#+=), only while `symbolsPage`.
  var morePage = false

  // Internal, not private: the model's typing, mic and phase halves live in
  // KeyboardModel+Typing/+Mic/+Phase.swift.
  @ObservationIgnored weak var controller: UIInputViewController?
  @ObservationIgnored private var observers: [DarwinObserver] = []
  @ObservationIgnored var gate = DictationKeyGate()
  @ObservationIgnored let clockStart = ContinuousClock.now
  @ObservationIgnored var lastResultID: UUID?
  @ObservationIgnored private var heartbeat: Task<Void, Never>?
  @ObservationIgnored var lastSpaceAt: ContinuousClock.Instant?
  @ObservationIgnored var noticeDwell: Task<Void, Never>?
  /// This keyboard process, for results addressed to it (`DictationResult.recipient`).
  @ObservationIgnored let instanceID = UUID().uuidString
  /// Where commands go: the App Group, or a test's capture.
  @ObservationIgnored var transport: (KeyboardCommand) -> Void = { command in
    SharedStore.write(command, forKey: BlurtShared.Key.command)
    SharedStore.post(BlurtShared.Signal.command)
  }
  /// A press that got no phase back is re-signalled once (a Darwin
  /// notification can be missed), after this long.
  static let commandRetryDelay: Duration = .milliseconds(600)
  @ObservationIgnored var commandRetry: Task<Void, Never>?
  @ObservationIgnored var termDraftFromSelection: String?
  /// A highlighted word the chip is done with — added, or its ✓ tapped —
  /// while the host still shows it highlighted: the + is back, and stays
  /// back until the highlight moves to another word or goes.
  @ObservationIgnored var dismissedSelection: String?
  /// The text before and after the cursor when the term field opened, so
  /// typing that reaches the host field anyway (a hardware keyboard: an
  /// iPad's, a Bluetooth one, the simulator's Mac) can be pulled into the
  /// term instead — and a cursor move, which changes both sides, cannot be
  /// mistaken for it.
  @ObservationIgnored var termHostBaseline: String?
  @ObservationIgnored var termHostBaselineAfter: String?
  @ObservationIgnored var termNotice: Task<Void, Never>?
  /// A release made while the mic was still coming up (the engine drops
  /// one before it records): held, and sent on the first recording phase.
  @ObservationIgnored var releasePending = false
  /// The press the app has not answered yet. A settled phase that does not
  /// answer it (the previous dictation's notice landing late) leaves the
  /// gate alone; anything in flight, or a phase carrying its id, answers it.
  @ObservationIgnored var unansweredPress: UUID?
  /// When `unansweredPress` went out. Past `BlurtShared.commandFreshnessWindow`
  /// the app drops it unread (or was never there to read it), so no answer
  /// is coming: see `expireUnansweredPress`.
  @ObservationIgnored var unansweredPressSentAt: Date?
  /// The `at` of a notice the keyboard already let go of: a re-read of the
  /// same snapshot cannot replay it.
  @ObservationIgnored var dismissedNoticeAt: Date?

  /// The host's text field. Tests hand in a fake in place of a controller.
  var proxy: (any UITextDocumentProxy)? { proxyOverride ?? controller?.textDocumentProxy }
  @ObservationIgnored var proxyOverride: (any UITextDocumentProxy)?

  /// The chosen theme's palette in the host's appearance — or, for a
  /// preview, whatever it is told.
  var palette: KeyboardPalette { paletteOverride ?? .resolve(themeID, dark: isDark) }
  var themeID = SharedStore.themeID
  var paletteOverride: KeyboardPalette?
  /// TEMPORARY: which mic concept draws, from Settings — or, for a preview
  /// or a gallery row, whatever it is told. Goes with the losers.
  var voiceKind: VoiceElementKind { voiceKindOverride ?? storedVoiceKind }
  var storedVoiceKind = SharedStore.voiceElementKind
  var voiceKindOverride: VoiceElementKind?
  /// Where the mic key sits across the row, from Settings (one hand: at the
  /// thumb's edge) — or, for a preview or a gallery row, whatever it is told.
  var micAlignment: MicAlignment { micAlignmentOverride ?? storedMicAlignment }
  var storedMicAlignment = SharedStore.micAlignment
  var micAlignmentOverride: MicAlignment?
  /// Whether the app being typed in wants a dark keyboard: what its field
  /// asks for, else the app's own light or dark appearance.
  var isDark = false

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
    // Only the panel has two pages, and not while the keys are up for a term.
    guard layout == .panel, termDraft == nil else { return }
    flipTowardsLeading = towardsLeading
    panelShowsKeys.toggle()
    onLayoutChange?()
  }

  /// Whether the phase leaves nothing in flight — the moments the gate has to
  /// be reset, since a dictation can end with no finger event to close it.
  var isSettled: Bool {
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
    // Without a controller (a test's model) the access stays as it was set.
    hasFullAccess = controller?.hasFullAccess ?? hasFullAccess
    needsGlobe = controller?.needsInputModeSwitchKey ?? true
    letterRows = LetterLayout.forPreferredLanguages()
    // Every appearance starts on the mic page with no term half-typed, and on
    // the page the field asks for: symbols for a number, letters otherwise.
    panelShowsKeys = false
    termDraft = nil
    termDraftFromSelection = nil
    termHostBaseline = nil
    termHostBaselineAfter = nil
    dismissedSelection = nil
    termNotice?.cancel()
    termSavedAt = nil
    releasePending = false
    // `unansweredPress` is not reset here: an appearance can follow another
    // with no disappearance between (iOS does that), and a press still out
    // must keep the gate latched so hands-free does not press again over it.
    // One too old for the app to take is over, though (`expireUnansweredPress`).
    symbolsPage = Self.wantsSymbols(proxy?.keyboardType)
    morePage = false
    readAppearance()
    readField()
    readSelection()
    updateShift()
    // Without Full Access the App Group is out of reach: the keyboard still
    // types, and says what it needs (see `VoiceBar`), but nothing below can
    // run — and nothing from a previous appearance (a phase, a latched gate)
    // may linger over a keyboard that can't hear the app.
    guard hasFullAccess else {
      snapshot = .idle
      gate.reset()
      noticeDwell?.cancel()
      return
    }
    layout = SharedStore.layout
    themeID = SharedStore.themeID
    storedVoiceKind = SharedStore.voiceElementKind
    storedMicAlignment = SharedStore.micAlignment
    SharedStore.keyboardEverSeen = true
    refresh(haptics: false)
    // `refresh` may apply no phase at all (none stored, or a notice already
    // let go of), so a press the app will never answer is let go of here too:
    // otherwise its latch would skip hands-free on every appearance after.
    if expireUnansweredPress(), isSettled { gate.reset() }
    startHeartbeat()
    requestLexicon()
    // Words that landed while this keyboard was away, still fresh and meant
    // for whoever is up, go in now rather than waiting for a signal nobody
    // will send again.
    resultArrived()
    if SharedStore.autoDictate { autoStart() }
  }

  /// Hands-free: a dictation begins the moment the keyboard is up, as if the
  /// mic had been tapped — the same synthetic tap through the engine's gate,
  /// so it latches and the next real tap stops it. Only when the app is
  /// listening and nothing is in flight; otherwise the orb sits dimmed and the
  /// first tap opens Blurt.
  private func autoStart() {
    guard isListening, isSettled, gate.isIdle else { return }
    perform(gate.modifierDown(at: elapsed))
    perform(gate.modifierUp(at: elapsed))
  }

  /// The keyboard is leaving the screen. A dictation it started must not run
  /// on without it: a latched recording is released (the words still land, on
  /// the clipboard if no keyboard is there to take them), anything earlier is
  /// cancelled. Words already being transcribed are left to finish — the mic
  /// is off, and a cancel would throw them away. Presence ends, so a result
  /// that finishes after this goes to the clipboard rather than to a keyboard
  /// nobody can see.
  func disappeared() {
    heartbeat?.cancel()
    heartbeat = nil
    commandRetry?.cancel()
    if !gate.isIdle || !isSettled {
      switch snapshot.state {
      case .recording: send(.release)
      case .processing: break
      case .idle, .connecting, .pasted, .copied, .error: send(.cancel)
      }
      gate.reset()
    }
    SharedStore.keyboardSeenAt = nil
  }

  deinit {
    heartbeat?.cancel()
    noticeDwell?.cancel()
    termNotice?.cancel()
    commandRetry?.cancel()
  }

  /// The cursor moved or the text around it changed, including by our own
  /// typing: re-read where the sentence stands and what the field wants.
  func contextChanged() {
    readAppearance()
    readField()
    readSelection()
    claimHostTypingForTerm()
    updateShift()
  }

  /// While the term field is open, characters that arrived in the host field
  /// (a hardware keyboard types past the on-screen keys) belong to the term:
  /// move them over and take them back out of the field. Only a short,
  /// appended run right after where the cursor was; anything else is left.
  /// Never when the field opened over a highlighted word: a tap that
  /// collapses that highlight to its end grows the text before the cursor
  /// by exactly the word, which is not typing, and taking it would delete
  /// the user's word.
  private func claimHostTypingForTerm() {
    guard termDraft != nil, termDraftFromSelection == nil, let baseline = termHostBaseline, let proxy else {
      return
    }
    let now = proxy.documentContextBeforeInput ?? ""
    let delta = now.count - baseline.count
    // Typing lengthens the text before the cursor by one character at a time
    // and leaves the text after it alone; a cursor move changes both; a
    // selection is neither; a block (a paste, the system's own dictation
    // under the keyboard) is never typing and stays in the field.
    guard delta == 1, proxy.selectedText == nil,
      (proxy.documentContextAfterInput ?? "") == (termHostBaselineAfter ?? ""),
      now.dropLast(delta).hasSuffix(baseline.suffix(24))
    else { return }
    let typed = String(now.suffix(delta))
    proxy.deleteBackward()
    termDraft?.append(typed)
    termHostBaseline = proxy.documentContextBeforeInput ?? ""
  }

  /// Auto-capitalisation, as the system keyboard does it: shift comes on at
  /// the start of a sentence (or of every word, or always) according to what
  /// the field asks for, and goes off after one letter.
  func updateShift() {
    if let termDraft {
      // A key term is usually a name, or two: capitalised to start and after
      // a space, then as typed.
      shifted = termDraft.isEmpty || termDraft.last == " "
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

  /// Catches up with whatever the app last published. No haptics: nothing
  /// just happened, the keyboard merely came up. A notice (pasted, copied,
  /// error) was for the keyboard that was up when it happened, not this
  /// appearance; a dictation in flight with the app gone is over.
  private func refresh(haptics: Bool) {
    isListening = SharedStore.isListening
    guard let current = SharedStore.read(PhaseSnapshot.self, forKey: BlurtShared.Key.phase) else { return }
    apply(current.isStale || current.noticeDwellSeconds != nil ? .idle : current, haptics: haptics)
  }

  /// Tells the app the keyboard is on screen, so a finished dictation is
  /// handed here rather than copied to the clipboard.
  private func startHeartbeat() {
    heartbeat?.cancel()
    heartbeat = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        SharedStore.keyboardSeenAt = Date()
        SharedStore.keyboardInstance = instanceID
        isListening = SharedStore.isListening
        try? await Task.sleep(for: .seconds(SharedStore.keyboardHeartbeatInterval))
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
}
