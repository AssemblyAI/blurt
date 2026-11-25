import Foundation
import Testing

@testable import BlurtiOSCore

/// One handshake's world: a fixed clock, one app launch, and the events as
/// the model would build them. Shared with `PressHandshakeStopTests` and
/// `PressHandshakeGateTests`.
enum HandshakeFixture {
  static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
  static let app = UUID()

  static let lift = PressHandshake.Event.micUp(heldFor: 0.1)
  static let holdLift = PressHandshake.Event.micUp(heldFor: 0.5)

  static func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

  static func ack(_ outcome: CommandAck.Outcome, for id: UUID) -> PressHandshake.Event {
    .ack(CommandAck(commandID: id, launchID: app, outcome: outcome, at: epoch))
  }

  static func published(
    _ state: PhaseSnapshot.State, answers: UUID? = nil, dictation: UUID? = nil, reason: FailureReason? = nil
  ) -> PressHandshake.Event {
    .phase(
      PhaseSnapshot(
        state: state,
        message: nil,
        level: 0,
        at: epoch,
        reason: reason,
        answers: answers,
        dictation: dictation.map { DictationRef(id: $0, ownerProcessID: nil) }
      )
    )
  }

  static func record(
    _ window: ListeningState.Window, micLive: Bool = true, reason: FailureReason? = nil
  ) -> ListeningState {
    ListeningState(launchID: app, sequence: 1, window: window, micLive: micLive, reason: reason, writtenAt: epoch)
  }

  static func micDown(
    ready: Bool = true, reason: FailureReason? = nil, phase: PhaseSnapshot.State = .idle, inFlight: UUID? = nil
  ) -> PressHandshake.Event {
    let ref = inFlight.map { DictationRef(id: $0, ownerProcessID: nil) }
    return .micDown(ready: ready, reason: reason, phase: phase, inFlight: ref)
  }

  /// A press from rest, out and unanswered.
  static func pressed(_ handshake: inout PressHandshake) -> UUID {
    _ = handshake.handle(micDown(), now: epoch)
    let id = UUID()
    _ = handshake.handle(.pressSent(id: id, at: epoch), now: epoch)
    return id
  }

  /// A tap from rest the app answered: the keyboard owns the dictation, at `phase`.
  static func owned(_ handshake: inout PressHandshake, phase: PhaseSnapshot.State = .connecting) -> UUID {
    let id = pressed(&handshake)
    _ = handshake.handle(lift, now: epoch)
    let dictation = UUID()
    _ = handshake.handle(ack(.started(dictation), for: id), now: epoch)
    if phase != .connecting { _ = handshake.handle(published(phase, dictation: dictation), now: epoch) }
    return dictation
  }

  /// A dictation the keyboard owns and has pressed again at 5 s, its stop
  /// out: the handshake is stopping, awaiting the stop's answer.
  static func stopping(_ handshake: inout PressHandshake) -> (dictation: UUID, stop: UUID) {
    let dictation = owned(&handshake, phase: .recording)
    _ = handshake.handle(micDown(phase: .recording, inFlight: dictation), now: at(5))
    let stop = UUID()
    _ = handshake.handle(.stopSent(id: stop, at: at(5)), now: at(5))
    return (dictation, stop)
  }

  /// A press from rest the app answered with busy, the finger still down:
  /// latched onto their dictation.
  static func foreignViaBusy(_ handshake: inout PressHandshake) -> UUID {
    let id = pressed(&handshake)
    let dictation = UUID()
    _ = handshake.handle(ack(.busy(dictation), for: id), now: epoch)
    return dictation
  }

  /// A finger down from rest over their dictation, visibly running.
  static func foreignViaLatch(_ handshake: inout PressHandshake) -> UUID {
    let dictation = UUID()
    _ = handshake.handle(micDown(phase: .recording, inFlight: dictation), now: epoch)
    return dictation
  }
}
