import BlurtEngine
import Foundation
import UIKit

// MARK: - The mic key: the engine's gate, driven by the finger

extension KeyboardModel {
  /// Whether a tap on the orb can do anything but open the app.
  package var isReady: Bool { hasFullAccess && isListening }

  /// What the voice control shows, from the phase the app published.
  package var voiceState: VoiceState { VoiceState(snapshot: snapshot, isReady: isReady) }

  /// Finger down on the orb. Ignored, with a buzz, while the last dictation
  /// is still being transcribed: a press then would be dropped by the engine
  /// and the user would talk into nothing.
  package func micDown() {
    guard isReady else { return }
    switch snapshot.state {
    case .connecting, .processing:
      if hasFullAccess { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
      return
    case .idle, .recording, .pasted, .copied, .error:
      let action = gate.modifierDown(at: elapsed)
      if action == .start { pressSentOver = snapshot.state }
      perform(action)
    }
  }

  /// Finger up. When Blurt isn't ready — no Full Access, or the app isn't
  /// listening — this is the tap that opens the app, whose checklist says what
  /// is missing (opening the app needs no Full Access; everything else does).
  /// The gate comes up either way, so a press the finger made while the app
  /// was still there is never left armed.
  package func micUp() {
    perform(gate.modifierUp(at: elapsed))
    if !isReady { openApp() }
  }

  package func cancel() {
    gate.reset()
    send(.cancel)
  }

  package var elapsed: Duration { clockStart.duration(to: ContinuousClock.now) }

  package func perform(_ action: DictationKeyGate.Action) {
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
    // A latch keeps the recording going; only the Mac's read-aloud router acts on it.
    case .none, .latch: break
    }
  }

  package func send(_ kind: KeyboardCommand.Kind) {
    let command = KeyboardCommand(
      id: UUID(), kind: kind, priorText: proxy?.documentContextBeforeInput,
      selectedText: proxy?.selectedText, sentAt: Date(), keyboard: instanceID)
    transport(command)
    unansweredPressCommand = kind == .press ? command : nil
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

  /// Lets go of a press the app can no longer answer — it drops one older
  /// than `BlurtShared.commandFreshnessWindow` unread, and an app that was
  /// killed answers nothing — so its latch can't outlive it. True when it did.
  @discardableResult
  package func expireUnansweredPress() -> Bool {
    guard let press = unansweredPressCommand, !press.isFresh() else { return false }
    unansweredPressCommand = nil
    return true
  }

  /// The gate's half of the same rule: a latch held only for an expired
  /// press goes with it, once nothing is in flight.
  func letGoOfExpiredPress() {
    if expireUnansweredPress(), isSettled { gate.reset() }
  }

  /// A swipe that began on the orb (the panel's carousel) after its press
  /// went out: undo exactly what that press did. A fresh press is cancelled;
  /// a press over a recording a tap had latched only re-latches it, so
  /// flipping to the keys mid-dictation doesn't throw the words away; a press
  /// the orb ignored (busy, or Blurt not ready) undoes nothing.
  ///
  /// Nor does a fresh press sent over a dictation the app was still running:
  /// the picture can say recording for a moment after this keyboard released
  /// it (leaving the screen, opening the term field), and the engine drops a
  /// press then, so it started nothing — a cancel would land on the words
  /// being transcribed.
  package func undoPress() {
    let action = gate.otherKeyDown()
    if action == .cancel, pressSentOver == .recording || pressSentOver == .processing { return }
    perform(action)
  }
}
