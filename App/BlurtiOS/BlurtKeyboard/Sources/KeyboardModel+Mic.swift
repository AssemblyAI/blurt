import BlurtEngine
import Foundation
import UIKit

// MARK: - The mic key: the engine's gate, driven by the finger

extension KeyboardModel {
  /// Whether a tap on the orb can do anything but open the app.
  var isReady: Bool { hasFullAccess && isListening }

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
  func micUp() {
    guard isReady else {
      openApp()
      return
    }
    perform(gate.modifierUp(at: elapsed))
  }

  func cancel() {
    gate.reset()
    send(.cancel)
  }

  var elapsed: Duration { clockStart.duration(to: ContinuousClock.now) }

  func perform(_ action: DictationKeyGate.Action) {
    switch action {
    case .start: send(.press)
    case .stop: send(.release)
    case .cancel: send(.cancel)
    case .none: break
    }
  }

  func send(_ kind: KeyboardCommand.Kind) {
    let command = KeyboardCommand(
      id: UUID(), kind: kind, priorText: proxy?.documentContextBeforeInput,
      selectedText: proxy?.selectedText, sentAt: Date())
    transport(command)
    // A press the app never answers (the notification was missed) would
    // leave the gate latched over nothing; one re-signal covers it.
    commandRetry?.cancel()
    guard kind == .press else { return }
    let stateAtSend = snapshot.state
    commandRetry = Task { [weak self] in
      try? await Task.sleep(for: Self.commandRetryDelay)
      guard !Task.isCancelled, let self, snapshot.state == stateAtSend else { return }
      SharedStore.post(BlurtShared.Signal.command)
    }
  }

}
