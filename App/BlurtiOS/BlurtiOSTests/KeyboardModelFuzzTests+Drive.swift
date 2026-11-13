import Foundation

@testable import BlurtiOSCore

// The event → model call table, apart from the fuzz loop and its checks so
// neither crowds the other.
extension KeyboardModelFuzzTests {
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func drive(_ rig: KeyboardRig, _ event: Event, _ random: inout Random) {
    let (model, proxy) = (rig.model, rig.proxy)
    switch event {
    case .micDown: model.micDown()
    case .micUp: model.micUp()
    case .cancel: model.cancel()
    case .swipeOffOrb:
      // A swipe that began on the orb and travelled after its press went
      // out: the press, then its undo — the swipe's end is never a lift.
      model.micDown()
      model.undoPress()
    case .phaseIdle: model.apply(snapshot(.idle))
    case .phaseConnecting: model.apply(phase(.connecting, model, &random))
    case .phaseRecording: model.apply(phase(.recording, model, &random))
    case .phaseProcessing: model.apply(phase(.processing, model, &random))
    case .phasePasted: model.apply(phase(.pasted, model, &random))
    case .phaseCopied: model.apply(snapshot(.copied))
    case .phaseError: model.apply(snapshot(.error, reason: random.coin() ? .micSilent : nil))
    case .answerConnecting:
      model.apply(snapshot(.connecting, dictation: UUID(), answers: model.handshake.pressID))
    case .answerError:
      model.apply(snapshot(.error, answers: model.handshake.pressID, reason: .micBusy))
    case .ackStarted: answerPress(rig, .started(UUID()))
    case .ackBusy: answerPress(rig, .busy(UUID()))
    case .ackNotListening: answerPress(rig, .notListening(.interrupted))
    case .ackEnded:
      // The app answers the last stop: the dictation it named, or nothing in flight.
      guard let stop = rig.commands.sent.last, stop.kind != .press else { return }
      if let dictation = stop.dictationID {
        rig.answer(stop.kind == .cancel ? .cancelled(dictation) : .stopped(dictation), to: stop)
      } else {
        rig.answer(.nothingInFlight, to: stop)
      }
    case .deadline:
      // The clock past both deadlines, for one tick; then back, so the
      // record's lease reads as it really is.
      let clock = model.now
      model.now = { clock().addingTimeInterval(BlurtShared.pressDeadline + 0.1) }
      model.tick()
      model.now = clock
    case .appNotListening:
      KeyboardRig.listening(false)
      model.stateChanged()
      model.apply(model.snapshot)
    case .appListening:
      KeyboardRig.listening(true)
      model.stateChanged()
      model.apply(model.snapshot)
    case .stateClosed:
      KeyboardRig.record(.closed, reason: .sessionOff)
      model.stateChanged()
    case .stateInterrupted:
      KeyboardRig.record(.interrupted, reason: .interrupted)
      model.stateChanged()
    case .stateLapsed:
      KeyboardRig.record(.open, micLive: true, age: ListeningState.lease + 1)
      model.stateChanged()
    case .beginTerm: model.beginAddingTerm()
    case .cancelTerm: model.cancelAddingTerm()
    case .saveTerm: model.saveTerm()
    case .termType: model.termType(random.pick(["a", "B", "z"]))
    case .termSpace: model.termSpace()
    case .termDelete: model.termDelete()
    case .termReturn: model.termReturn()
    case .selectWord:
      proxy.selected = "Rizz"
      model.contextChanged()
    case .selectOther:
      proxy.selected = random.pick(["Gyatt", "neil bisht", " Rizz "])
      model.contextChanged()
    case .clearSelection:
      proxy.selected = nil
      model.contextChanged()
    case .addSelected: model.addSelectedTerm()
    case .dismissSelected: model.dismissSelection()
    case .appeared:
      model.hasFullAccess = true
      model.appeared()
    case .appearedNoAccess:
      // Without Full Access the keyboard can't reach the app: whatever was
      // in flight is the app's to end.
      model.hasFullAccess = false
      model.appeared()
      model.hasFullAccess = true
    case .disappeared: model.disappeared()
    case .hostLeaving: model.hostLeaving()
    case .contextChanged: model.contextChanged()
    case .resultFresh:
      SharedStore.write(
        DictationResult(id: UUID(), text: "words", deliveredAt: Date(), recipient: nil), forKey: BlurtShared.Key.result)
      model.resultArrived()
    case .resultStale:
      SharedStore.write(
        DictationResult(id: UUID(), text: "old", deliveredAt: Date().addingTimeInterval(-60), recipient: nil),
        forKey: BlurtShared.Key.result)
      model.resultArrived()
    case .resultForOther:
      SharedStore.write(
        DictationResult(id: UUID(), text: "theirs", deliveredAt: Date(), recipient: "someone-else"),
        forKey: BlurtShared.Key.result)
      model.resultArrived()
    case .hostTyped:
      proxy.before += "x"
      model.contextChanged()
    case .hostMovedCursor:
      proxy.before += "ab"
      proxy.after = String(proxy.after.dropFirst(2))
      model.contextChanged()
    }
  }

  /// An in-flight phase or a notice as the app would publish it: naming the
  /// dictation the handshake knows, or another one, or none.
  private func phase(_ state: PhaseSnapshot.State, _ model: KeyboardModel, _ random: inout Random) -> PhaseSnapshot {
    switch random.next() % 3 {
    case 0: snapshot(state)
    case 1: snapshot(state, dictation: model.handshake.dictationID ?? UUID())
    default: snapshot(state, dictation: UUID())
    }
  }

  /// The app answers the last press this keyboard sent, if there was one.
  private func answerPress(_ rig: KeyboardRig, _ outcome: CommandAck.Outcome) {
    guard let press = rig.lastPress else { return }
    rig.answer(outcome, to: press)
  }
}
