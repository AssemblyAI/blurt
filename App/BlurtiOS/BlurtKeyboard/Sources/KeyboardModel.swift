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
  var layout: KeyboardLayout = .panel
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

  var proxy: (any UITextDocumentProxy)? { controller?.textDocumentProxy }

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
      DarwinObserver(name: BlurtShared.Signal.phase) {
        Task { @MainActor [weak self] in self?.phaseChanged() }
      },
      DarwinObserver(name: BlurtShared.Signal.result) {
        Task { @MainActor [weak self] in self?.resultArrived() }
      },
    ]
  }

  func appeared() {
    hasFullAccess = controller?.hasFullAccess ?? false
    needsGlobe = controller?.needsInputModeSwitchKey ?? true
    // Without Full Access the App Group is out of reach: the keyboard still
    // types, and says what it needs (see `KeyboardRootView`), but nothing below
    // can run.
    guard hasFullAccess else { return }
    layout = SharedStore.layout
    SharedStore.keyboardEverSeen = true
    refresh()
    startHeartbeat()
    requestLexicon()
  }

  func disappeared() {
    heartbeat?.cancel()
    heartbeat = nil
  }

  func contextChanged() {}

  private func refresh() {
    isListening = SharedStore.isListening
    if let current = SharedStore.read(PhaseSnapshot.self, forKey: BlurtShared.Key.phase) {
      apply(current)
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
    controller?.requestSupplementaryLexicon { @Sendable lexicon in
      let entries = lexicon.entries.map {
        LexiconEntry(userInput: $0.userInput, documentText: $0.documentText)
      }
      SharedStore.write(entries, forKey: BlurtShared.Key.lexicon)
      SharedStore.post(BlurtShared.Signal.lexicon)
    }
  }

  // MARK: - The mic key

  func micDown() {
    guard hasFullAccess else { return }
    guard isListening else {
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
    apply(current)
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
  }

  private func resultArrived() {
    guard let result = SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result),
      result.id != lastResultID, let proxy
    else { return }
    lastResultID = result.id
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

  func space() { proxy?.insertText(" ") }

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
