import BlurtEngine
import Foundation
import Observation
import UIKit

/// The keyboard's state and its side of the conversation with the app: it
/// sends press / release / cancel with the text around the cursor, shows the
/// phase the app publishes, and inserts the words that come back.
///
/// The press is `PressHandshake`'s: every finger event, signal and clock tick
/// goes in as one of its events, and the actions it answers are carried out
/// here (`KeyboardModel+Handshake.swift`). The mic key's tap-versus-hold rule
/// is the engine's own `DictationKeyGate`, driven by the finger instead of a
/// modifier key — the handshake says when a touch is the gate's, and is fed
/// the same stamps, so the two agree.
@MainActor
@Observable
package final class KeyboardModel {
  /// How old a result may be and still be inserted. Darwin notifications are
  /// held for a suspended process and delivered when it resumes, so the
  /// keyboard inside the app the user *left* hears about a dictation done
  /// elsewhere minutes later; anything older than this is not its to insert.
  package static let resultFreshnessWindow: TimeInterval = 10
  /// The phone's word list is re-read at most this often. Contacts change by
  /// the day, and reading thousands of them on every appearance is what the
  /// keyboard's memory budget cannot afford.
  package static let lexiconRefreshInterval: TimeInterval = 60 * 60
  /// A press or a stop the app has not answered is re-signalled once (a
  /// Darwin notification can be missed), after this long — the handshake's
  /// retry delay, well inside its deadlines.
  package static let commandRetryDelay: Duration = .milliseconds(600)

  package var layout: KeyboardLayout = .panel
  /// The panel is a two-page carousel — the mic panel and the full keyboard —
  /// flipped by a swipe in either direction, as often as you like. Which page
  /// is up; back to the mic each time the keyboard appears.
  package var panelShowsKeys = false
  /// The direction of the last flip, so the pages slide the way the finger went.
  package var flipTowardsLeading = false
  package var snapshot = PhaseSnapshot.idle
  /// The app's readiness record as last read (`SharedStore.listeningState`):
  /// at every appearance, signal, heartbeat and tap. Nil until an app has
  /// written one, or without Full Access.
  package var listeningState: ListeningState?
  /// The keyboard's press, as a state machine (`PressHandshake`). Observable,
  /// so the status line and the picture follow it.
  package var handshake = PressHandshake(retryDelay: KeyboardModel.commandRetryDelay / .seconds(1))
  /// The press went out and the app has not answered: the element works
  /// from this moment, not from the app's first phase.
  package var showsConnecting = false
  /// The last `.error` the app published, kept for the status line after the
  /// ring's dwell settles the picture back to idle; cleared by the next tap.
  package var heldError: PhaseSnapshot?
  /// When this keyboard last put the words into the field — the orb's drop.
  package var resultLandedAt: Date?
  /// The key term being typed on the keys, while the voice bar is a field;
  /// nil otherwise. See `beginAddingTerm`.
  package var termDraft: String?
  /// When the last term was saved, so the bar can show a check for a moment.
  package var termSavedAt: Date?
  /// The word highlighted in the host's text, when it could be a key term
  /// (`termCandidate`) and the key terms are in reach (Full Access): the +
  /// grows into a chip holding it, and one tap adds it. Read off the proxy
  /// on every context change (`readSelection`); the gallery sets it.
  package var selectedTerm: String?
  /// Whether `selectedTerm` is already one of Blurt's key terms: the chip
  /// shows a check and adds nothing.
  package var selectedTermIsKnown = false
  /// The field's own return key, as iOS labels it: "send", "search", "go"…
  package var returnLabel: String?
  /// The letter rows for the user's first keyboard language (AZERTY for
  /// French, QWERTZ for German and its neighbours, QWERTY otherwise).
  package var letterRows = LetterLayout.qwerty
  /// Whether a press would record now, as the readiness record says
  /// (`readListeningState`). A preview sets it by hand with no record behind it.
  package var isListening = false
  package var hasFullAccess = false
  package var needsGlobe = true
  package var shifted = true
  package var symbolsPage = false
  /// The symbols' second page (#+=), only while `symbolsPage`.
  package var morePage = false
  /// Bumped by the notice clock so the status line's timed rows — the
  /// countdown, the transcription's patience — are read again.
  package var noticeTick = 0

  // Internal, not private: the model's typing, mic, phase, handshake,
  // presence and notice halves live in KeyboardModel+*.swift.
  @ObservationIgnored package weak var controller: UIInputViewController?
  @ObservationIgnored package var observers: [DarwinObserver] = []
  @ObservationIgnored package var gate = DictationKeyGate()
  @ObservationIgnored package var lastResultID: UUID?
  /// What the last dictation put in the field, separator included, so one
  /// delete takes the whole of it back. Any keystroke into the host clears it,
  /// and so does the keyboard leaving the screen.
  @ObservationIgnored package var lastInsertion: Insertion?
  @ObservationIgnored package var heartbeat: Task<Void, Never>?
  @ObservationIgnored package var lastSpaceAt: ContinuousClock.Instant?
  @ObservationIgnored package var noticeDwell: Task<Void, Never>?
  /// The one-shot ticks at the handshake's retry delay and deadline while a
  /// press or stop is out, and the command they are for.
  @ObservationIgnored package var ticks: [Task<Void, Never>] = []
  @ObservationIgnored package var ticking: UUID?
  /// The status line's timer: every second through a recording's last
  /// stretch, once a transcription has run past its patience.
  @ObservationIgnored package var noticeClock: Task<Void, Never>?
  /// This controller — one per host field — within the process (`KeyboardProcess.id`).
  @ObservationIgnored package let controllerID = UUID().uuidString
  /// The last command written, kept whole for the handshake's resend: the
  /// same id and stamp again, so an app that did read it ignores the copy.
  @ObservationIgnored package var lastCommand: KeyboardCommand?
  /// When the finger touched the mic, on the clock the gate is fed, and
  /// whether that touch armed the gate from rest: what the lift is judged by.
  @ObservationIgnored package var touchDown: Duration?
  @ObservationIgnored package var armedFromIdle = false
  /// The clock, injected so a test can move it: the handshake's stamps and
  /// deadlines, the gate's stamps and every freshness check read it.
  @ObservationIgnored package var now: () -> Date = { Date() }
  @ObservationIgnored private let clockStart = Date()
  /// How `openApp` asks the application object, once the responder chain
  /// reaches it: a test's capture in place of really opening the app.
  @ObservationIgnored var urlOpener: (UIApplication, URL) -> Void = { application, url in
    application.open(url, options: [:], completionHandler: nil)
  }
  /// Where commands go: the App Group, or a test's capture.
  @ObservationIgnored package var transport: (KeyboardCommand) -> Void = { command in
    SharedStore.write(command, forKey: BlurtShared.Key.command)
    SharedStore.post(BlurtShared.Signal.command)
  }
  @ObservationIgnored package var termDraftFromSelection: String?
  /// A highlighted word the chip is done with — added, or its ✓ tapped —
  /// while the host still shows it highlighted: the + is back, and stays
  /// back until the highlight moves to another word or goes.
  @ObservationIgnored package var dismissedSelection: String?
  /// The text before and after the cursor when the term field opened, so
  /// typing that reaches the host field anyway (a hardware keyboard: an
  /// iPad's, a Bluetooth one, the simulator's Mac) can be pulled into the
  /// term instead — and a cursor move, which changes both sides, cannot be
  /// mistaken for it.
  @ObservationIgnored package var termHostBaseline: String?
  @ObservationIgnored package var termHostBaselineAfter: String?
  @ObservationIgnored package var termNotice: Task<Void, Never>?
  /// The `at` of a notice the keyboard already let go of: a re-read of the
  /// same snapshot cannot replay it.
  @ObservationIgnored package var dismissedNoticeAt: Date?

  /// The host's text field. Tests hand in a fake in place of a controller.
  package var proxy: (any UITextDocumentProxy)? { proxyOverride ?? controller?.textDocumentProxy }
  @ObservationIgnored package var proxyOverride: (any UITextDocumentProxy)?

  /// The chosen theme, by id. Its colours are the shell's: `palette`
  /// (KeyboardModel+Palette.swift) resolves this, in the host's appearance.
  package var themeID = SharedStore.themeID
  /// For a preview: this theme face, whatever Settings and the host say.
  package var faceOverride: ThemeFace?
  /// The face to draw: the preview's, else the chosen theme in the host's
  /// appearance — as `voiceKind` and `micAlignment` resolve theirs.
  package var face: ThemeFace { faceOverride ?? ThemeFace(themeID: themeID, dark: isDark) }
  /// TEMPORARY: which mic concept draws, from Settings — or, for a preview
  /// or a gallery row, whatever it is told. Goes with the losers.
  package var voiceKind: VoiceElementKind { voiceKindOverride ?? storedVoiceKind }
  package var storedVoiceKind = SharedStore.voiceElementKind
  package var voiceKindOverride: VoiceElementKind?
  /// Where the mic key sits across the row, from Settings (one hand: at the
  /// thumb's edge) — or, for a preview or a gallery row, whatever it is told.
  package var micAlignment: MicAlignment { micAlignmentOverride ?? storedMicAlignment }
  package var storedMicAlignment = SharedStore.micAlignment
  package var micAlignmentOverride: MicAlignment?
  /// Whether the app being typed in wants a dark keyboard: what its field
  /// asks for, else the app's own light or dark appearance.
  package var isDark = false

  /// What is actually on screen: the panel's carousel may be showing its
  /// keys, and typing a key term needs them whatever the layout.
  package var effectiveLayout: KeyboardLayout {
    if termDraft != nil { return .full }
    return layout == .panel && panelShowsKeys ? .full : layout
  }

  /// Told when `effectiveLayout` changes, so the host can resize the keyboard.
  @ObservationIgnored package var onLayoutChange: (() -> Void)?

  /// A horizontal swipe on the panel: flip to the other page, sliding the way
  /// the finger went.
  package func flipPanel(towardsLeading: Bool) {
    // Only the panel has two pages, and not while the keys are up for a term.
    guard layout == .panel, termDraft == nil else { return }
    flipTowardsLeading = towardsLeading
    panelShowsKeys.toggle()
    onLayoutChange?()
  }

  /// Whether the phase leaves nothing in flight — the moments the gate has to
  /// be reset, since a dictation can end with no finger event to close it.
  package var isSettled: Bool { snapshot.state.isSettled }

  /// The gate's clock: seconds since this model was made, on the same clock
  /// the handshake's stamps use, so a hold is one length to both.
  package var elapsed: Duration { .seconds(now().timeIntervalSince(clockStart)) }

  package init() {}

  deinit {
    heartbeat?.cancel()
    noticeDwell?.cancel()
    noticeClock?.cancel()
    termNotice?.cancel()
    ticks.forEach { $0.cancel() }
  }

  /// The cursor moved or the text around it changed, including by our own
  /// typing: re-read where the sentence stands and what the field wants.
  package func contextChanged() {
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
  package func updateShift() {
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

  package static func isSentenceStart(_ before: String) -> Bool {
    let trimmed = before.reversed().drop { $0 == " " }
    guard let last = trimmed.first else { return true }
    return last == "\n" || ".?!".contains(last)
  }
}
