import BlurtEngine
import Foundation
import UIKit

// MARK: - Carrying out the handshake's actions

extension KeyboardModel {
  /// Performs what the handshake asked for, in order, then keeps the ticks
  /// in step with whatever it is waiting on now. A send feeds the handshake
  /// its `pressSent` / `stopSent` from inside, so by the time the next action
  /// runs the state already holds the command's id and stamp.
  package func perform(_ actions: [PressHandshake.Action]) {
    for action in actions { act(on: action) }
    if handshake.pressID == nil { showsConnecting = false }
    // The stop a leave was held behind is answered, or given up at its
    // deadline: presence ends now rather than at the grace (`disappeared`).
    if leaving != nil, handshake.stopID == nil { leave() }
    syncTicks()
  }

  private func act(on action: PressHandshake.Action) {
    switch action {
    case .armGate, .resetGate, .latch: touchGate(action)
    case .sendPress, .sendRelease, .sendCancel: dispatch(action)
    case .resendPress(let id), .resendStop(let id): resend(id)
    case .showConnecting, .show, .hop, .buzz, .none: react(to: action)
    }
  }

  /// The gate is the handshake's to touch, and only through these three: a
  /// press from rest or a finger down over a latch arms it with the touch's
  /// own stamp; nothing to hold resets it; a dictation this keyboard didn't
  /// start is latched over with a synthetic tap, so the gate holds it.
  private func touchGate(_ action: PressHandshake.Action) {
    switch action {
    case .armGate:
      _ = gate.modifierDown(at: touchDown ?? elapsed)
    case .resetGate:
      gate.reset()
    case .latch:
      guard gate.isIdle else { return }
      _ = gate.modifierDown(at: elapsed)
      _ = gate.modifierUp(at: elapsed)
    default:
      break
    }
  }

  private func dispatch(_ action: PressHandshake.Action) {
    switch action {
    case .sendPress:
      let command = send(.press, dictation: nil)
      perform(handshake.handle(.pressSent(id: command.id, at: command.sentAt), now: now()))
    case .sendRelease(let dictation):
      let command = send(.release, dictation: dictation)
      perform(handshake.handle(.stopSent(id: command.id, at: command.sentAt), now: now()))
    case .sendCancel(let dictation):
      let command = send(.cancel, dictation: dictation)
      perform(handshake.handle(.cancelSent(id: command.id, at: command.sentAt), now: now()))
    default:
      break
    }
  }

  private func react(to action: PressHandshake.Action) {
    switch action {
    case .showConnecting:
      showsConnecting = true
    case .show(let reason):
      KeyboardLog.refused(reason)
    case .hop(let reason):
      hop(reason: reason)
    case .buzz:
      if hasFullAccess { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    default:
      break
    }
  }

  /// Writes one command to the app. Only a press primes the request with the
  /// field's text; a release or a cancel carries none of it across, and
  /// names the dictation it ends so an ending can't land on a later one.
  @discardableResult
  private func send(_ kind: KeyboardCommand.Kind, dictation: UUID?) -> KeyboardCommand {
    let isPress = kind == .press
    let command = KeyboardCommand(
      id: UUID(), kind: kind, priorText: isPress ? proxy?.documentContextBeforeInput : nil,
      selectedText: isPress ? proxy?.selectedText : nil, sentAt: now(), keyboard: KeyboardProcess.id,
      seq: KeyboardProcess.nextSequence(), controllerID: controllerID, dictationID: dictation,
      stateSequence: listeningState?.sequence)
    lastCommand = command
    transport(command)
    KeyboardLog.wrote(command, resend: false)
    return command
  }

  /// The same command again — the id, the stamp, the text — so an app that
  /// did read it answers it as before and one that missed it takes it now.
  private func resend(_ id: UUID) {
    guard let command = lastCommand, command.id == id else { return }
    transport(command)
    KeyboardLog.wrote(command, resend: true)
  }

  /// Brings the app forward, saying why: `blurt://start?reason=` normally —
  /// the one way a window opens, since iOS lets no capture start from the
  /// background — or the app's setup when there is no Full Access to dictate
  /// with (iOS 18 opens it from here; a later iOS may refuse an extension
  /// without Full Access the open, which the setup line then has to say).
  private func hop(reason: FailureReason?) {
    let url =
      hasFullAccess
      ? BlurtShared.startURL(reason: reason, host: hostBundleID)
      : BlurtShared.setupURL(need: BlurtShared.fullAccessNeed)
    openApp(url: url)
  }

  // MARK: The clock

  /// The handshake's two moments while a command is out: the retry delay and
  /// the deadline, each a one-shot task from the command's own stamp. Kept
  /// for the command the handshake is waiting on; a new one replaces them.
  private func syncTicks() {
    let awaiting = handshake.pressID ?? handshake.stopID
    guard awaiting != ticking else { return }
    cancelTicks()
    ticking = awaiting
    guard awaiting != nil, let sentAt = awaitingSince else { return }
    let deadline = handshake.pressID != nil ? handshake.pressDeadline : handshake.stopDeadline
    ticks = [handshake.retryDelay, deadline].map { delay in
      let due = sentAt.addingTimeInterval(delay)
      return Task { [weak self] in
        guard let self else { return }
        try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSince(now()))))
        guard !Task.isCancelled else { return }
        tick()
      }
    }
  }

  package func cancelTicks() {
    ticks.forEach { $0.cancel() }
    ticks = []
    ticking = nil
  }

  /// When the command the handshake is waiting on went out.
  private var awaitingSince: Date? {
    switch handshake.state {
    case .pressing(_, let sentAt, _, _), .stopping(_, _, let sentAt, _): sentAt
    case .idle, .owned, .foreign, .unready: nil
    }
  }

  /// The clock, on the handshake's scale: a resend if it is due, the
  /// deadline if it has passed.
  package func tick() {
    let awaiting = handshake.pressID
    let actions = handshake.handle(.tick(now: now()), now: now())
    if let awaiting, let reason = handshake.unreadyReason, actions.contains(.show(reason)) {
      KeyboardLog.deadline(command: awaiting, reason: reason)
    }
    perform(actions)
  }
}
