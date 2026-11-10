import Foundation
import Testing

@testable import BlurtiOSCore

// The swipe off the orb — the press's undo — apart from the press and its
// answers, so neither file crowds the other.
extension KeyboardModelGateTests {
  @Test("a swipe off the orb undoes only its own press: a fresh one is cancelled, a latched recording kept")
  func undoPress() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let commands = rig.commands
    // A swipe whose press went out from idle: taken back, nameless.
    model.micDown()
    model.undoPress()
    #expect(commands.sent.map(\.kind) == [.press, .cancel])
    #expect(commands.sent.last?.dictationID == nil)
    rig.answer(.nothingInFlight)
    #expect(model.gate.isIdle)
    // A mic coming up for our press: cancelled, by its id.
    model.apply(snapshot(.idle))
    model.micDown()
    let coming = UUID()
    rig.answer(.started(coming))
    model.undoPress()
    #expect(commands.sent.map(\.kind) == [.press, .cancel, .press, .cancel])
    #expect(commands.sent.last?.dictationID == coming)
    rig.answer(.cancelled(coming))
    // A finger down over a recording is its stop, sent at once; a swipe
    // after it undoes nothing (the words are kept).
    model.apply(snapshot(.idle))
    let dictation = rig.latchRecording()
    model.micDown()
    #expect(commands.sent.count == 6)
    #expect(commands.sent.last?.kind == .release && commands.sent.last?.dictationID == dictation)
    model.undoPress()
    #expect(commands.sent.count == 6)
    #expect(!model.gate.isIdle)
  }

  @Test("a swipe over a recording this keyboard just released cancels nothing: those words are being transcribed")
  func undoPressOverReleasedRecording() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let commands = rig.commands
    rig.latchRecording()
    // Leaving the screen releases it; the app hasn't published `.processing`
    // yet, so the picture still says recording.
    model.disappeared()
    #expect(commands.sent.map(\.kind) == [.press, .release])
    // A swipe across the orb in that moment: the release is out, so the
    // finger down pressed nothing, and there is nothing to undo.
    model.micDown()
    model.undoPress()
    #expect(commands.sent.map(\.kind) == [.press, .release])
  }
}
