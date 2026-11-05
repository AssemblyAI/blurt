import BlurtEngine
import BlurtiOSCore
import Foundation

// MARK: - Commands from the keyboard, and the dictation's owner
//
// Every command the keyboard writes is answered with an ack (`CommandRouter`
// decides; this carries it out), a dictation is owned by the keyboard process
// whose press started it, and the watchdog ends one whose owner is gone.

extension DictationCoordinator {
  /// How many answered command ids are kept, so a resend of any recent one is
  /// answered the same way (`CommandRouter`); the oldest make room.
  static let answeredCapacity = 32

  /// A command landed (`Signal.command`): decided, acknowledged, and — when
  /// the router says so — submitted to the session.
  func handleCommand() {
    guard let command = SharedStore.read(KeyboardCommand.self, forKey: BlurtShared.Key.command) else { return }
    // The command is consumed: nothing re-reads it, and the text it carried
    // from the user's field doesn't sit in the group container.
    SharedStore.remove(forKey: BlurtShared.Key.command)
    let decision = CommandRouter.route(
      CommandRouter.Input(
        command: command, state: window.state, phase: routerPhase, inFlight: inFlight,
        onScreen: SharedStore.keyboardOnScreen()?.processID, answered: answered, launchID: window.launchID))
    SharedStore.acknowledge(decision.ack)
    if decision.remember { remember(command.id, decision.ack.outcome) }
    log(command, decision)
    guard let submit = decision.submit else { return }
    lastCommandID = command.id
    switch submit {
    case .press(let newDictation, let owner):
      Self.pendingPress.withLock {
        $0 = Press(
          keyboard: command.keyboard,
          context: FocusedFieldContext(
            priorText: command.priorText, selectedText: command.selectedText, windowTitle: nil, fieldLabel: nil))
      }
      inFlight = DictationRef(id: newDictation, ownerProcessID: owner)
      answers = command.id
      watchdogReleased = nil
      session.submit(.press())
    case .release:
      Self.claimedPress.withLock { $0.stopRecipient = decision.recipient }
      session.submit(.release)
    case .cancel:
      Self.claimedPress.withLock { $0.stopRecipient = decision.recipient }
      session.submit(.cancel)
    }
  }

  /// The phase the router decides on. A press just submitted is in flight
  /// before the session's `.connecting` has rendered: a second press in that
  /// gap latches onto it rather than being promised a dictation of its own.
  private var routerPhase: PhaseSnapshot.State {
    let rendered = PhaseSnapshot.State(overlay)
    return inFlight != nil && rendered.isSettled ? .connecting : rendered
  }

  private func remember(_ id: UUID, _ outcome: CommandAck.Outcome) {
    answered[id] = outcome
    answeredOrder.append(id)
    while answeredOrder.count > Self.answeredCapacity {
      answered.removeValue(forKey: answeredOrder.removeFirst())
    }
  }

  private func log(_ command: KeyboardCommand, _ decision: CommandRouter.Decision) {
    let keyboard = command.keyboard ?? "unnamed"
    let outcome = decision.ack.outcome.logName
    let verdict = decision.submit == nil ? "refused:\(outcome)" : "accepted:\(outcome)"
    Self.log.notice(
      "\(command.kind.rawValue, privacy: .public) \(command.id, privacy: .public) from \(keyboard, privacy: .public) → \(verdict, privacy: .public)"
    )
    let fields = [
      "id": command.id.uuidString, "kind": command.kind.rawValue, "keyboard": keyboard, "outcome": outcome,
      "submitted": String(decision.submit != nil),
    ]
    DeviceTrace.record("command", fields)
  }

  // MARK: The owner's watchdog

  /// Every keyboard beat, asks whether the dictation in flight still has its
  /// keyboard; the `keyboard` signal asks at once.
  func watchOwner() -> Task<Void, Never> {
    Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(SharedStore.keyboardHeartbeatInterval))
        guard !Task.isCancelled else { return }
        self?.tickWatchdog()
      }
    }
  }

  /// A dictation whose keyboard is gone is released, once, with its words
  /// kept: they go to the clipboard, as they would with no keyboard to take
  /// them. Under the release's background task, like any release.
  func tickWatchdog() {
    guard let inFlight, watchdogReleased != inFlight.id,
      OwnerWatchdog.shouldRelease(inFlight: inFlight, presence: SharedStore.keyboardPresence, now: Date())
    else { return }
    watchdogReleased = inFlight.id
    Self.log.notice("watchdog released \(inFlight.id, privacy: .public): its keyboard is gone")
    DeviceTrace.record("watchdog", ["dictation": inFlight.id.uuidString])
    window.backgroundTasks.begin(Self.releaseTask)
    session.submit(.release)
  }

  // MARK: The dictation's end

  /// The terminal phase has been published with the press it answered and
  /// the dictation it named: nothing is in flight now, the words have landed
  /// or been copied, and the background task around the release is over.
  func dictationEnded(_ phase: PipelinePhase) {
    window.backgroundTasks.end(Self.releaseTask)
    if let inFlight {
      let outcome =
        switch phase {
        case .pasted: "inserted"
        case .noTarget: "copied"
        case .cancelled: "cancelled"
        default: "failed"
        }
      Self.log.notice("result for \(inFlight.id, privacy: .public) → \(outcome, privacy: .public)")
      DeviceTrace.record("result", ["dictation": inFlight.id.uuidString, "outcome": outcome])
    }
    inFlight = nil
    answers = nil
    Self.claimedPress.withLock { $0.stopRecipient = nil }
  }

  // MARK: The press the session takes

  /// The session accepted a press: the last one asked for becomes the
  /// dictation's, and is no longer pending. Nil, as the frontmost app: there is
  /// none to paste into on the iPhone; the words go back to the keyboard.
  nonisolated static func claimPress() -> CapturedFocus? {
    let press = pendingPress.withLock { pending in
      defer { pending = Press() }
      return pending
    }
    claimedPress.withLock { $0 = press }
    return nil
  }

  /// What the keyboard saw around the cursor on the press in flight, once.
  nonisolated static func fieldContext() -> FocusedFieldContext {
    claimedPress.withLock { press in
      defer { press.context = .empty }
      return press.context
    }
  }
}

extension CommandAck.Outcome {
  /// The outcome as the log names it: the case, and the reason where one rides along.
  var logName: String {
    switch self {
    case .started: "started"
    case .busy: "busy"
    case .stopped: "stopped"
    case .cancelled: "cancelled"
    case .notListening(let reason): "notListening(\(reason.rawValue))"
    case .notOwner: "notOwner"
    case .nothingInFlight: "nothingInFlight"
    case .stale: "stale"
    case .duplicate: "duplicate"
    }
  }
}
