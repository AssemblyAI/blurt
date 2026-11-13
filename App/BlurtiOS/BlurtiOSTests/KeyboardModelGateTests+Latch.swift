import Foundation
import Testing

@testable import BlurtiOSCore

/// The latch over a dictation this keyboard didn't start, the stop and its
/// timing, the × and the record's changes, driven through the model. The
/// press and its answers are in `KeyboardModelGateTests.swift`.
@Suite("Keyboard model: the latch, the stop and the record", .serialized)
@MainActor
struct KeyboardModelLatchTests {

  @Test("a dictation started elsewhere latches on the finger, and one tap stops it with its id")
  func foreignLatches() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let dictation = UUID()
    model.apply(snapshot(.recording, dictation: dictation))
    // Nothing is latched until a finger comes down over it.
    #expect(model.gate.isIdle && model.handshake.isIdle)
    model.tapMic()
    #expect(rig.commands.sent.map(\.kind) == [.release])
    #expect(rig.commands.sent.last?.dictationID == dictation)
    rig.answer(.stopped(dictation))
    #expect(model.gate.isIdle && model.handshake.isIdle)
  }

  @Test("a running dictation the app has not named takes no press and no stop: a buzz, the gate untouched")
  func unnamedInFlight() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    rig.model.apply(snapshot(.recording))
    rig.model.tapMic()
    #expect(rig.commands.sent.isEmpty)
    #expect(rig.model.gate.isIdle && rig.model.handshake.isIdle)
  }

  @Test("ack busy: the press latches onto the dictation; its lift leaves it running, the next tap stops it")
  func busy() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    model.micDown()
    let theirs = UUID()
    rig.answer(.busy(theirs))
    #expect(!model.gate.isIdle)
    #expect(model.handshake.state == .foreign(dictation: theirs))
    model.micUp()
    #expect(rig.commands.sent.map(\.kind) == [.press])
    #expect(!model.gate.isIdle)
    // Their dictation shows as the app publishes it; the next tap stops it.
    model.apply(snapshot(.recording, dictation: theirs))
    model.tapMic()
    #expect(rig.commands.sent.map(\.kind) == [.press, .release])
    #expect(rig.commands.sent.last?.dictationID == theirs)
  }

  @Test("ack notListening: the press is refused, the line says why, and the next tap opens Blurt with the reason")
  func notListening() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let (hops, window) = rig.capturingHops()
    defer { window.isHidden = true }
    model.tapMic()
    rig.answer(.notListening(.interrupted))
    #expect(model.gate.isIdle)
    #expect(model.handshake.unreadyReason == .interrupted)
    #expect(model.statusLine == VoiceNotice.Line(text: VoiceNotice.Copy.interrupted, tapOpens: .hop(.interrupted)))
    model.tapMic()
    #expect(hops.opened == [BlurtShared.startURL(reason: .interrupted)])
    #expect(rig.commands.sent.map(\.kind) == [.press])
  }

  @Test("a stop during connecting is a release at once: a second tap before the mic is up")
  func releaseWhileConnecting() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let start = Date()
    let dictation = Self.pressedAndStarted(rig, at: start, phase: .connecting)
    model.now = { start.addingTimeInterval(1.2) }
    model.micUp()
    model.tapMic()
    #expect(rig.commands.sent.map(\.kind) == [.press, .release])
    #expect(rig.commands.sent.last?.dictationID == dictation)
    #expect(model.handshake.stopID != nil)
  }

  @Test("a second tap before the answer releases the moment the answer names the dictation")
  func secondTapBeforeAnswer() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let start = Date()
    model.now = { start }
    model.micDown()
    model.now = { start.addingTimeInterval(1.1) }
    model.micUp()
    model.micDown()
    #expect(rig.commands.sent.map(\.kind) == [.press])
    let dictation = UUID()
    rig.answer(.started(dictation))
    #expect(rig.commands.sent.map(\.kind) == [.press, .release])
    #expect(rig.commands.sent.last?.dictationID == dictation)
  }

  @Test("a hold: the press on the finger down, the release the instant it lifts")
  func holdToTalk() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let start = Date()
    let dictation = Self.pressedAndStarted(rig, at: start, phase: .recording)
    rig.model.now = { start.addingTimeInterval(0.5) }
    rig.model.micUp()
    #expect(rig.commands.sent.map(\.kind) == [.press, .release])
    #expect(rig.commands.sent.last?.dictationID == dictation)
  }

  /// A finger down at `start`, answered with a started dictation that the
  /// app then publishes at `phase`; the finger is still down.
  private static func pressedAndStarted(_ rig: KeyboardRig, at start: Date, phase: PhaseSnapshot.State) -> UUID {
    rig.model.now = { start }
    rig.model.micDown()
    let dictation = UUID()
    rig.answer(.started(dictation))
    rig.model.apply(snapshot(phase, dictation: dictation))
    return dictation
  }

  @Test("the × cancels with the dictation's id, and the gate comes up on the app's answer")
  func cancel() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let dictation = rig.latchRecording()
    model.cancel()
    #expect(rig.commands.sent.map(\.kind) == [.press, .cancel])
    #expect(rig.commands.sent.last?.dictationID == dictation)
    #expect(!model.gate.isIdle)
    rig.answer(.cancelled(dictation))
    #expect(model.gate.isIdle && model.handshake.isIdle)
    // At rest the × sends nothing.
    model.cancel()
    #expect(rig.commands.sent.count == 2)
  }

  @Test("the record closing ends a press out or a latch, never a dictation this keyboard owns; a lapsed lease ends all")
  func recordChanges() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let pressing = KeyboardRig()
    pressing.model.tapMic()
    KeyboardRig.listening(false)
    pressing.model.stateChanged()
    #expect(pressing.model.gate.isIdle)
    #expect(pressing.model.handshake.unreadyReason == .sessionOff)
    #expect(pressing.model.statusLine?.text == VoiceNotice.Copy.tapToOpen)
    #expect(!pressing.model.isReady)
    // Owned: the app is alive to end the dictation itself.
    let owned = KeyboardRig()
    let dictation = owned.latchRecording()
    KeyboardRig.record(.closed, reason: .sessionOff)
    owned.model.stateChanged()
    #expect(owned.model.handshake.state == .owned(dictation: dictation, phase: .recording))
    #expect(!owned.model.gate.isIdle)
    // The lease lapsed: the app is suspended or gone, and so is its dictation.
    KeyboardRig.record(.open, micLive: true, age: ListeningState.lease + 1)
    owned.model.stateChanged()
    #expect(owned.model.gate.isIdle)
    #expect(owned.model.handshake.unreadyReason == .suspended)
    #expect(owned.model.statusLine == VoiceNotice.Line(text: VoiceNotice.Copy.tapToOpen, tapOpens: .hop(.suspended)))
    // Ready again, with the app's picture settled, the handshake rests and a
    // tap presses.
    KeyboardRig.listening(true)
    owned.model.stateChanged()
    owned.model.apply(snapshot(.idle))
    #expect(owned.model.handshake.isIdle && owned.model.isReady && owned.model.statusLine == nil)
    owned.model.tapMic()
    #expect(owned.commands.sent.last?.kind == .press)
  }

  @Test("a phase in flight with the app's lease lapsed is a picture of nothing: idle, no mic nobody can stop")
  func inFlightWithAppGone() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    KeyboardRig.record(.open, micLive: true, age: ListeningState.lease + 1)
    model.apply(snapshot(.recording, dictation: UUID()))
    #expect(model.snapshot.state == .idle)
    #expect(!model.isReady)
    // A notice still shows for its dwell, whoever published it.
    model.apply(snapshot(.copied))
    #expect(model.snapshot.state == .copied)
  }
}
