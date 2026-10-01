import BlurtEngine
import Foundation
import UIKit

// MARK: - The mic key: the engine's gate, driven by the finger

extension KeyboardModel {
  /// Whether a tap on the orb can do anything but open the app.
  var isReady: Bool { hasFullAccess && isListening }

  /// What the voice control shows, from the phase the app published.
  var voiceState: VoiceState { VoiceState(snapshot: snapshot, isReady: isReady) }

  /// Finger down on the orb. Ignored, with a buzz, while the last dictation
  /// is still being transcribed: a press then would be dropped by the engine
  /// and the user would talk into nothing.
  func micDown() {
    guard isReady else { return }
    switch snapshot.state {
    case .connecting, .processing:
      if hasFullAccess { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
      return
    case .idle, .recording, .pasted, .copied, .error:
      perform(gate.modifierDown(at: elapsed))
    }
  }

  /// Finger up. When Blurt isn't ready — no Full Access, or the app isn't
  /// listening — this is the tap that opens the app, whose checklist says what
  /// is missing (opening the app needs no Full Access; everything else does).
  /// The gate comes up either way, so a press the finger made while the app
  /// was still there is never left armed.
  func micUp() {
    perform(gate.modifierUp(at: elapsed))
    if !isReady { openApp() }
  }

  func cancel() {
    gate.reset()
    send(.cancel)
  }

  var elapsed: Duration { clockStart.duration(to: ContinuousClock.now) }

  func perform(_ action: DictationKeyGate.Action) {
    switch action {
    case .start: send(.press)
    case .stop:
      // The engine drops a release before it is recording (the mic still
      // coming up): hold it for the first recording phase instead.
      if snapshot.state == .connecting {
        releasePending = true
      } else {
        send(.release)
      }
    case .cancel:
      releasePending = false
      send(.cancel)
    case .none: break
    }
  }

  func send(_ kind: KeyboardCommand.Kind) {
    let command = KeyboardCommand(
      id: UUID(), kind: kind, priorText: proxy?.documentContextBeforeInput,
      selectedText: proxy?.selectedText, sentAt: Date(), keyboard: instanceID)
    transport(command)
    unansweredPress = kind == .press ? command.id : nil
    // A press the app never answers would leave the gate latched over
    // nothing. Either notification can be missed: first catch up with a phase
    // the app may have published unheard; if the picture is still as it was,
    // the press itself was missed — put it back (the app takes a command out
    // of the store as it reads it) and signal again. The same id, so an app
    // that did read it ignores the copy.
    commandRetry?.cancel()
    guard kind == .press else { return }
    let stateAtSend = snapshot.state
    commandRetry = Task { [weak self] in
      try? await Task.sleep(for: Self.commandRetryDelay)
      guard !Task.isCancelled, let self else { return }
      phaseChanged()
      guard snapshot.state == stateAtSend else { return }
      transport(command)
    }
  }

}
