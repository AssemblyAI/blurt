import Foundation
import Testing

@testable import BlurtiOSCore

/// The release and cancel rows, over the fixtures `CommandRouterTests` declares.
extension CommandRouterTests {
  @Test("a release or cancel with nothing in flight has nothing to end")
  func nothingInFlight() {
    for kind in [KeyboardCommand.Kind.release, .cancel] {
      let decision = route(command(kind), phase: .idle, inFlight: nil)
      #expect(decision.ack.outcome == .nothingInFlight, "\(kind)")
      #expect(decision.submit == nil)
      #expect(decision.remember)
      #expect(decision.recipient == nil)
    }
  }

  @Test("in flight means the same for every row: a terminal phase has nothing to end, whatever ref was left")
  func nothingInFlightOverStaleRef() {
    for kind in [KeyboardCommand.Kind.release, .cancel] {
      for phase in [PhaseSnapshot.State.idle, .pasted, .copied, .error] {
        let decision = route(command(kind, dictationID: current.id), phase: phase, inFlight: current)
        #expect(decision.ack.outcome == .nothingInFlight, "\(kind) \(phase)")
        #expect(decision.submit == nil)
        #expect(decision.recipient == nil)
      }
    }
  }

  @Test("an in-flight phase with no ref has no dictation to end either")
  func nothingInFlightWithoutRef() {
    for kind in [KeyboardCommand.Kind.release, .cancel] {
      let decision = route(command(kind), phase: .recording, inFlight: nil)
      #expect(decision.ack.outcome == .nothingInFlight, "\(kind)")
      #expect(decision.submit == nil)
    }
  }

  @Test("the owner's release stops the dictation in flight, addressed to the owner")
  func ownerRelease() {
    let decision = route(command(.release, dictationID: current.id), phase: .recording, inFlight: current)
    #expect(decision.ack.outcome == .stopped(current.id))
    #expect(decision.submit == .release)
    #expect(decision.remember)
    #expect(decision.recipient == owner)
  }

  @Test("the owner's cancel cancels it, addressed to the owner, whether or not it names the dictation")
  func ownerCancel() {
    for dictationID in [current.id, nil] {
      let decision = route(command(.cancel, dictationID: dictationID), phase: .recording, inFlight: current)
      #expect(decision.ack.outcome == .cancelled(current.id), "\(String(describing: dictationID))")
      #expect(decision.submit == .cancel)
      #expect(decision.recipient == owner)
    }
  }

  @Test("an accepted ending is stopped or cancelled in every in-flight phase")
  func endingEveryInFlightPhase() {
    for phase in [PhaseSnapshot.State.connecting, .recording, .processing] {
      let stopped = route(command(.release), phase: phase, inFlight: current)
      let cancelled = route(command(.cancel), phase: phase, inFlight: current)
      #expect(stopped.ack.outcome == .stopped(current.id), "\(phase)")
      #expect(cancelled.ack.outcome == .cancelled(current.id), "\(phase)")
    }
  }

  @Test("a release that names no dictation ends the one in flight")
  func releaseWithoutDictationID() {
    let decision = route(command(.release), phase: .connecting, inFlight: current)
    #expect(decision.ack.outcome == .stopped(current.id))
    #expect(decision.submit == .release)
  }

  @Test("a release for an older dictation is not the owner's to make")
  func releaseOlderDictation() {
    let decision = route(command(.release, dictationID: UUID()), phase: .recording, inFlight: current)
    #expect(decision.ack.outcome == .notOwner)
    #expect(decision.submit == nil)
    #expect(decision.recipient == nil)
  }

  @Test("a release from the keyboard on screen is accepted though it is not the owner, and addressed to it")
  func releaseFromOnScreen() {
    let decision = route(command(.release, keyboard: other), phase: .recording, inFlight: current, onScreen: other)
    #expect(decision.ack.outcome == .stopped(current.id))
    #expect(decision.submit == .release)
    #expect(decision.recipient == other)
  }

  @Test("a cancel from the keyboard on screen is accepted too")
  func cancelFromOnScreen() {
    let decision = route(command(.cancel, keyboard: other), phase: .recording, inFlight: current, onScreen: other)
    #expect(decision.ack.outcome == .cancelled(current.id))
    #expect(decision.submit == .cancel)
    #expect(decision.recipient == other)
  }

  @Test("a release from a keyboard that neither owns the dictation nor is on screen is refused")
  func releaseNotOwner() {
    for onScreen in [nil, owner, "keyboard-third"] {
      let decision = route(command(.release, keyboard: other), phase: .recording, inFlight: current, onScreen: onScreen)
      #expect(decision.ack.outcome == .notOwner, "on screen: \(String(describing: onScreen))")
      #expect(decision.submit == nil)
      #expect(decision.remember)
      #expect(decision.recipient == nil)
    }
  }

  @Test("a cancel from a keyboard that neither owns the dictation nor is on screen is refused")
  func cancelNotOwner() {
    for onScreen in [nil, owner, "keyboard-third"] {
      let decision = route(command(.cancel, keyboard: other), phase: .recording, inFlight: current, onScreen: onScreen)
      #expect(decision.ack.outcome == .notOwner, "on screen: \(String(describing: onScreen))")
      #expect(decision.submit == nil)
      #expect(decision.recipient == nil)
    }
  }

  @Test("the on-screen match needs both sides named: an unnamed sender never passes as the keyboard on screen")
  func releaseUnnamedSender() {
    #expect(route(command(.release, keyboard: nil), phase: .recording, inFlight: current).ack.outcome == .notOwner)
    #expect(
      route(command(.release, keyboard: nil), phase: .recording, inFlight: current, onScreen: owner).ack.outcome
        == .notOwner)
  }

  @Test("a dictation nobody owns is ended by a command that names no sender, the old way")
  func releaseUnownedDictation() {
    let unowned = DictationRef(id: UUID(), ownerProcessID: nil)
    let decision = route(command(.release, keyboard: nil), phase: .recording, inFlight: unowned)
    #expect(decision.ack.outcome == .stopped(unowned.id))
    #expect(decision.submit == .release)
    #expect(decision.recipient == nil)
    #expect(route(command(.release, keyboard: other), phase: .recording, inFlight: unowned).ack.outcome == .notOwner)
  }

  @Test("a dictation nobody owns is ended by a named keyboard on screen, addressed to it")
  func releaseUnownedDictationFromOnScreen() {
    let unowned = DictationRef(id: UUID(), ownerProcessID: nil)
    for kind in [KeyboardCommand.Kind.release, .cancel] {
      let decision = route(command(kind, keyboard: other), phase: .recording, inFlight: unowned, onScreen: other)
      #expect(decision.ack.outcome == (kind == .release ? .stopped(unowned.id) : .cancelled(unowned.id)), "\(kind)")
      #expect(decision.submit == (kind == .release ? .release : .cancel))
      #expect(decision.recipient == other)
    }
  }

  @Test("a stop resent after its ack is answered stopped again, so the session is not told twice")
  func stopResend() {
    let release = command(.release, dictationID: current.id)
    let first = route(release, phase: .recording, inFlight: current)
    #expect(first.submit == .release)
    let resend = route(release, phase: .processing, inFlight: current, answered: [release.id: first.ack.outcome])
    #expect(resend.ack.outcome == .stopped(current.id))
    #expect(resend.submit == nil)
    #expect(!resend.remember)
  }
}
