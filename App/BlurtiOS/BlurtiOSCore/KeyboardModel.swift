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
  /// How long a keyboard that left the screen with its own release or cancel
  /// still out keeps its presence record on screen while it waits for the
  /// app's answer: the stop's own deadline (`BlurtShared.stopDeadline`). The
  /// record going off screen is what the app's watchdog reads as a dead
  /// keyboard, and the dictation this keyboard is ending itself must not be
  /// released a second time by the watchdog racing its command
  /// (`disappeared`, DESIGN.md › The two processes: leaving with a stop out).
  package static let leaveGrace: TimeInterval = BlurtShared.stopDeadline

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
  /// on every context change (`readSelection`).
  package var selectedTerm: String?
  /// Whether `selectedTerm` is already one of Blurt's key terms: the chip
  /// shows a check and adds nothing.
  package var selectedTermIsKnown = false
  /// Whether a press would record now, as the readiness record says
  /// (`readListeningState`). A preview sets it by hand with no record behind it.
  package var isListening = false
  package var hasFullAccess = false
  /// Bumped by the notice clock so the status line's timed rows — the
  /// countdown, the transcription's patience — are read again.
  package var noticeTick = 0

  // Internal, not private: the model's typing, mic, phase, handshake,
  // presence and notice halves live in KeyboardModel+*.swift.
  @ObservationIgnored package weak var controller: UIInputViewController?
  @ObservationIgnored package var observers: [DarwinObserver] = []
  @ObservationIgnored package var gate = DictationKeyGate()
  @ObservationIgnored package var lastResultID: UUID?
  @ObservationIgnored package var heartbeat: Task<Void, Never>?
  /// The leave held back behind a stop still out (`disappeared`): ends
  /// presence at `leaveGrace` unless the app's answer, or a return to the
  /// screen, gets there first.
  @ObservationIgnored package var leaving: Task<Void, Never>?
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
  /// The app this keyboard is up in (`HostApp.bundleID`), read on each
  /// appearance; the hop carries it so the app can come back to it.
  @ObservationIgnored package var hostBundleID: String?
  /// The last command written, kept whole for the handshake's resend: the
  /// same id and stamp again, so an app that did read it ignores the copy.
  @ObservationIgnored package var lastCommand: KeyboardCommand?
  /// When the finger touched the mic, on the clock the gate is fed.
  @ObservationIgnored package var touchDown: Duration?
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

  /// Whether the phase leaves nothing in flight — the moments the gate has to
  /// be reset, since a dictation can end with no finger event to close it.
  package var isSettled: Bool { snapshot.state.isSettled }

  /// The gate's clock: seconds since this model was made, on the same clock
  /// the handshake's stamps use, so a hold is one length to both.
  package var elapsed: Duration { .seconds(now().timeIntervalSince(clockStart)) }

  package init() {}

  deinit {
    heartbeat?.cancel()
    leaving?.cancel()
    noticeDwell?.cancel()
    noticeClock?.cancel()
    termNotice?.cancel()
    ticks.forEach { $0.cancel() }
  }

  /// The cursor moved or the text around it changed, including by our own
  /// typing: re-read the highlight, and take typing that reached the host
  /// while the term field is open. The sentence's case, the field's return
  /// key and its appearance are KeyboardKit's to read.
  package func contextChanged() {
    readSelection()
    claimHostTypingForTerm()
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

  /// The term's own case rule, for the keys while the field is open: a key
  /// term is usually a name, or two — capitalised to start and after a
  /// space, then as typed. The host's sentence is KeyboardKit's to read.
  package var termWantsUppercase: Bool {
    guard let termDraft else { return false }
    return termDraft.isEmpty || termDraft.last == " "
  }
}
