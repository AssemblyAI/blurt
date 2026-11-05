import Foundation
import Testing

@testable import BlurtiOSCore

/// The mic key's press through the handshake, against the app's answers:
/// which answer settles which press, the resend and the deadline, what every
/// command carries, and the term field closing a live dictation. The latch
/// over another keyboard's dictation, the stop and the record's changes are
/// in `KeyboardModelGateTests+Latch.swift`.
@Suite("Keyboard model: the handshake and the app's answers", .serialized)
@MainActor
struct KeyboardModelGateTests {

  @Test("a settled phase settles the gate only when it answers the press; an older notice does not")
  func resetOnSettled() throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let commands = rig.commands
    let (hops, window) = rig.capturingHops()
    defer { window.isHidden = true }
    model.tapMic()
    let press = try #require(rig.lastPress)
    #expect(!model.gate.isIdle)
    #expect(model.handshake.pressID == press.id)
    // The previous dictation's words land a moment after the press: not ours.
    model.apply(snapshot(.pasted, dictation: UUID()))
    #expect(!model.gate.isIdle)
    #expect(model.handshake.pressID == press.id)
    // The app answers, and the recording phase names the dictation: the
    // next tap is the stop, with that dictation's id.
    let dictation = UUID()
    rig.answer(.started(dictation))
    #expect(model.handshake.isOwned)
    model.apply(snapshot(.recording, dictation: dictation))
    model.tapMic()
    #expect(commands.sent.map(\.kind) == [.press, .release])
    #expect(commands.sent.last?.dictationID == dictation)
    rig.answer(.stopped(dictation))
    #expect(model.gate.isIdle && model.handshake.isIdle)
    // The words land and the picture settles.
    model.apply(snapshot(.pasted, dictation: dictation))
    model.apply(snapshot(.idle))
    // A phase that answers the press with an error settles it with the
    // reason; the line holds that reason until the next tap, which opens
    // Blurt with it, and a ready record then rests the handshake.
    model.tapMic()
    let second = try #require(rig.lastPress)
    model.apply(snapshot(.error, answers: second.id, reason: .micSilent))
    #expect(model.gate.isIdle)
    #expect(model.handshake.unreadyReason == .micSilent)
    #expect(model.statusLine?.text == FailureReason.micSilent.line)
    model.tapMic()
    #expect(hops.opened == [BlurtShared.startURL(reason: .micSilent)])
    #expect(model.heldError == nil)
    model.stateChanged()
    #expect(model.handshake.isIdle)
    // The picture settles after its dwell; the line goes with it.
    model.apply(snapshot(.idle))
    #expect(model.statusLine == nil)
    // An in-flight phase that answers it, naming its dictation, owns it, and
    // that dictation's end frees the gate.
    model.tapMic()
    let third = try #require(rig.lastPress)
    let named = UUID()
    model.apply(snapshot(.connecting, dictation: named, answers: third.id))
    #expect(model.handshake.isOwned && model.handshake.dictationID == named)
    model.apply(snapshot(.pasted, dictation: named))
    #expect(model.gate.isIdle && model.handshake.isIdle)
  }

  @Test("a command names this process and controller, counts up, and says which record it decided on")
  func commandCarriesSender() throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    rig.model.tapMic()
    let dictation = UUID()
    rig.answer(.started(dictation))
    rig.model.apply(snapshot(.recording, dictation: dictation))
    rig.model.tapMic()
    let sent = rig.commands.sent
    #expect(sent.map(\.kind) == [.press, .release])
    #expect(sent.allSatisfy { $0.keyboard == KeyboardProcess.id && $0.controllerID == rig.model.controllerID })
    let first = try #require(sent[0].seq)
    let second = try #require(sent[1].seq)
    #expect(second == first + 1)
    #expect(sent[0].stateSequence == SharedStore.listeningState?.sequence)
    #expect(sent[0].dictationID == nil && sent[1].dictationID == dictation)
  }

  @Test("a press the app never answers is sent again at the retry delay, the same id; one it answered is not")
  func pressRetried() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let commands = rig.commands
    let start = Date()
    model.now = { start }
    model.tapMic()
    model.now = { start.addingTimeInterval(0.3) }
    model.tick()
    #expect(commands.sent.count == 1)
    model.now = { start.addingTimeInterval(0.6) }
    model.tick()
    #expect(commands.sent.map(\.kind) == [.press, .press])
    #expect(commands.sent[0].id == commands.sent[1].id)
    model.now = { start.addingTimeInterval(0.9) }
    model.tick()
    #expect(commands.sent.count == 2)
    // Answered: nothing to send again.
    let answered = KeyboardRig()
    answered.model.now = { start }
    answered.model.tapMic()
    answered.answer(.started(UUID()))
    answered.model.now = { start.addingTimeInterval(0.6) }
    answered.model.tick()
    #expect(answered.commands.sent.count == 1)
  }

  @Test("the retry and the deadline fire on the clock by themselves")
  func pressTimers() async throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    model.tapMic()
    try await Task.sleep(for: KeyboardModel.commandRetryDelay + .milliseconds(300))
    #expect(rig.commands.sent.map(\.kind) == [.press, .press])
    try await Task.sleep(for: .seconds(BlurtShared.pressDeadline) - KeyboardModel.commandRetryDelay)
    #expect(model.handshake.unreadyReason == .unanswered)
    #expect(model.gate.isIdle)
    #expect(rig.commands.sent.count == 2)
  }

  @Test("an unanswered press expires at the deadline: the gate comes up, the line says so, and the next tap hops")
  func unansweredPressExpires() throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let (hops, window) = rig.capturingHops()
    defer { window.isHidden = true }
    let start = Date()
    model.now = { start }
    model.tapMic()
    model.now = { start.addingTimeInterval(BlurtShared.pressDeadline) }
    model.tick()
    #expect(model.gate.isIdle)
    #expect(model.handshake.unreadyReason == .unanswered)
    #expect(model.statusLine == VoiceNotice.Line(text: VoiceNotice.Copy.tapToOpen, tapOpens: .hop(.unanswered)))
    // The next tap opens Blurt, saying why — never a release.
    model.tapMic()
    #expect(hops.opened == [BlurtShared.startURL(reason: .unanswered)])
    #expect(rig.commands.sent.map(\.kind) == [.press])
    // Ready again, the press after that goes out as any other.
    model.stateChanged()
    model.tapMic()
    #expect(rig.commands.sent.map(\.kind) == [.press, .press])
    #expect(hops.opened.count == 1)
  }

  @Test("hands-free after an expired press presses afresh rather than skipping over a dead latch")
  func appearanceAfterExpiredPress() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let commands = rig.commands
    SharedStore.autoDictate = true
    let start = Date()
    model.now = { start }
    model.tapMic()
    model.now = { start.addingTimeInterval(BlurtShared.pressDeadline) }
    model.tick()
    model.now = { Date() }
    model.appeared()
    #expect(commands.sent.map(\.kind) == [.press, .press])
    #expect(model.handshake.pressID == commands.sent.last?.id)
  }

  @Test("the + over a live dictation closes it: a recording is released, a mic coming up cancelled, a press taken back")
  func termFieldClosesDictation() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let commands = rig.commands
    let dictation = rig.latchRecording()
    model.beginAddingTerm()
    #expect(commands.sent.map(\.kind) == [.press, .release])
    #expect(commands.sent.last?.dictationID == dictation)
    #expect(model.termDraft == "")
    // The gate stays the handshake's: it comes up when the stop is answered.
    #expect(!model.gate.isIdle)
    rig.answer(.stopped(dictation))
    #expect(model.gate.isIdle)
    model.cancelAddingTerm()
    model.apply(snapshot(.idle))
    // A mic still coming up is cancelled, by its id.
    model.tapMic()
    let coming = UUID()
    rig.answer(.started(coming))
    model.beginAddingTerm()
    #expect(commands.sent.map(\.kind) == [.press, .release, .press, .cancel])
    #expect(commands.sent.last?.dictationID == coming)
    rig.answer(.cancelled(coming))
    model.cancelAddingTerm()
    model.apply(snapshot(.idle))
    // A press the app hasn't answered is taken back, nameless.
    model.tapMic()
    model.beginAddingTerm()
    #expect(commands.sent.map(\.kind) == [.press, .release, .press, .cancel, .press, .cancel])
    #expect(commands.sent.last?.dictationID == nil)
    rig.answer(.nothingInFlight)
    model.cancelAddingTerm()
    // Nothing in flight: the field opens and nothing is sent.
    model.beginAddingTerm()
    #expect(commands.sent.count == 6)
  }

  @Test("the + while words are being transcribed lets them land; from a highlighted word it cancels them")
  func termFieldDuringProcessing() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let commands = rig.commands
    let dictation = rig.latchRecording()
    // The app auto-released, with no finger event: the gate is still latched.
    model.apply(snapshot(.processing, dictation: dictation))
    #expect(!model.gate.isIdle)
    model.beginAddingTerm()
    #expect(commands.sent.map(\.kind) == [.press])
    model.cancelAddingTerm()
    rig.proxy.selected = "Rizz"
    model.beginAddingTerm()
    #expect(commands.sent.map(\.kind) == [.press, .cancel])
    #expect(commands.sent.last?.dictationID == dictation)
  }

  @Test("leaving the screen while the words are being transcribed lets them finish")
  func disappearDuringProcessing() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let commands = rig.commands
    let dictation = rig.latchRecording()
    model.tapMic()
    model.apply(snapshot(.processing, dictation: dictation))
    model.disappeared()
    #expect(commands.sent.map(\.kind) == [.press, .release])
  }
}
