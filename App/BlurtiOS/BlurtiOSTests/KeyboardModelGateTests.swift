import Foundation
import Testing
import UIKit

@testable import BlurtiOS
@testable import BlurtiOSCore

/// The mic key's gate against the app's phases: which phase settles which
/// press, the retry, the sender on every command, and the term field closing
/// a live dictation.
@Suite("Keyboard model: the gate and the app's answers", .serialized)
@MainActor
struct KeyboardModelGateTests {
  struct Rig {
    let model: KeyboardModel
    let commands: Commands
  }

  final class Commands {
    var sent: [KeyboardCommand] = []
  }

  private func ready() -> Rig {
    let proxy = FakeProxy()
    let model = KeyboardModel()
    model.proxyOverride = proxy
    model.hasFullAccess = true
    let now = Date()
    SharedStore.listeningUntil = now.addingTimeInterval(600)
    SharedStore.appSeenAt = now
    model.isListening = true
    let commands = Commands()
    model.transport = { commands.sent.append($0) }
    return Rig(model: model, commands: commands)
  }

  private func snapshot(_ state: PhaseSnapshot.State, level: Double = 0) -> PhaseSnapshot {
    PhaseSnapshot(state: state, message: nil, level: level, at: Date())
  }

  @Test("a settled phase resets a latched gate — once it answers the press; an older notice does not")
  func resetOnSettled() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    let model = rig.model
    let commands = rig.commands
    model.micDown()
    model.micUp()
    #expect(!model.gate.isIdle)
    // The previous dictation's words land a moment after the press: not ours.
    model.apply(snapshot(.pasted))
    #expect(!model.gate.isIdle)
    // The next tap is still the stop, not a second press.
    model.micDown()
    model.micUp()
    #expect(commands.sent.map(\.kind) == [.press, .release])
    #expect(model.gate.isIdle)
    // A phase that answers the press settles it.
    model.micDown()
    model.micUp()
    let press = commands.sent.last?.id
    model.apply(PhaseSnapshot(state: .error, message: "no mic", level: 0, at: Date(), command: press))
    #expect(model.gate.isIdle)
    // And an in-flight phase answers it too, whatever id it carries.
    model.micDown()
    model.micUp()
    model.apply(snapshot(.connecting))
    #expect(model.unansweredPress == nil)
    model.apply(snapshot(.pasted))
    #expect(model.gate.isIdle)
  }

  @Test("a command names the keyboard that sent it")
  func commandCarriesSender() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    rig.model.micDown()
    rig.model.micUp()
    #expect(rig.commands.sent.map(\.keyboard) == [rig.model.instanceID])
  }

  @Test("a press the app never answers is sent again after the retry delay; one it answered is not")
  func pressRetried() async throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    let model = rig.model
    let commands = rig.commands
    model.micDown()
    model.micUp()
    try await Task.sleep(for: KeyboardModel.commandRetryDelay + .milliseconds(300))
    #expect(commands.sent.map(\.kind) == [.press, .press])
    #expect(commands.sent[0].id == commands.sent[1].id)
    // Answered: the app published a phase the keyboard reads on the retry.
    model.apply(PhaseSnapshot(state: .pasted, message: nil, level: 0, at: Date(), command: model.unansweredPress))
    model.micDown()
    model.micUp()
    SharedStore.write(snapshot(.recording), forKey: BlurtShared.Key.phase)
    try await Task.sleep(for: KeyboardModel.commandRetryDelay + .milliseconds(300))
    #expect(commands.sent.map(\.kind) == [.press, .press, .press])
    #expect(model.snapshot.state == .recording)
  }

  @Test(
    "opening the key-term field over a live dictation closes it: a recording is released, a mic coming up cancelled")
  func termFieldClosesDictation() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    let model = rig.model
    let commands = rig.commands
    model.micDown()
    model.micUp()
    model.apply(snapshot(.recording))
    model.beginAddingTerm()
    #expect(commands.sent.map(\.kind) == [.press, .release])
    #expect(model.gate.isIdle)
    #expect(model.termDraft == "")
    model.cancelAddingTerm()
    model.apply(snapshot(.idle))
    model.micDown()
    model.micUp()
    model.apply(snapshot(.connecting))
    model.beginAddingTerm()
    #expect(commands.sent.map(\.kind) == [.press, .release, .press, .cancel])
    #expect(model.gate.isIdle)
    // Nothing in flight: the field opens and nothing is sent.
    model.cancelAddingTerm()
    model.apply(snapshot(.idle))
    model.beginAddingTerm()
    #expect(commands.sent.count == 4)
  }

  @Test("the + while words are being transcribed lets them land; from a highlighted word it cancels them")
  func termFieldDuringProcessing() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    let model = rig.model
    let commands = rig.commands
    // A tap latched the gate; the app auto-released, with no finger event.
    model.micDown()
    model.micUp()
    model.apply(snapshot(.recording))
    model.apply(snapshot(.processing))
    #expect(!model.gate.isIdle)
    model.beginAddingTerm()
    #expect(commands.sent.map(\.kind) == [.press])
    #expect(model.gate.isIdle)
    model.cancelAddingTerm()
    (model.proxyOverride as? FakeProxy)?.selected = "Rizz"
    model.beginAddingTerm()
    #expect(commands.sent.map(\.kind) == [.press, .cancel])
  }

  @Test("leaving the screen while the words are being transcribed lets them finish")
  func disappearDuringProcessing() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    let model = rig.model
    let commands = rig.commands
    model.micDown()
    model.micUp()
    model.apply(snapshot(.recording))
    model.micDown()
    model.micUp()
    model.apply(snapshot(.processing))
    model.disappeared()
    #expect(commands.sent.map(\.kind) == [.press, .release])
    #expect(model.gate.isIdle)
  }

  @Test("a swipe off the orb undoes only its own press: a fresh one is cancelled, a latched recording kept")
  func undoPress() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    let model = rig.model
    let commands = rig.commands
    // A swipe whose press went out from idle: taken back.
    model.micDown()
    model.undoPress()
    #expect(commands.sent.map(\.kind) == [.press, .cancel])
    #expect(model.gate.isIdle)
    // A tap latches a recording; a swipe across the orb leaves it running,
    // and the next tap is still the stop.
    model.apply(snapshot(.idle))
    model.micDown()
    model.micUp()
    model.apply(snapshot(.recording))
    model.micDown()
    model.undoPress()
    #expect(commands.sent.map(\.kind) == [.press, .cancel, .press])
    #expect(!model.gate.isIdle)
    model.micDown()
    model.micUp()
    #expect(commands.sent.map(\.kind) == [.press, .cancel, .press, .release])
  }

  @Test("a press the app never answers stops holding the gate once it is too old for the app to take")
  func unansweredPressExpires() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    let model = rig.model
    model.micDown()
    model.micUp()
    #expect(!model.expireUnansweredPress())
    #expect(model.unansweredPress != nil)
    // A settled phase that doesn't answer it leaves the latch while it is fresh…
    model.apply(snapshot(.pasted))
    #expect(!model.gate.isIdle)
    // …and lets it go once the app would drop it unread.
    model.unansweredPressSentAt = Date().addingTimeInterval(-BlurtShared.commandFreshnessWindow - 1)
    model.apply(snapshot(.idle))
    #expect(model.unansweredPress == nil)
    #expect(model.gate.isIdle)
  }

  @Test("an appearance lets go of a press too old to be answered, so hands-free can start")
  func appearanceExpiresPress() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    let model = rig.model
    let commands = rig.commands
    SharedStore.autoDictate = true
    model.micDown()
    model.micUp()
    model.unansweredPressSentAt = Date().addingTimeInterval(-BlurtShared.commandFreshnessWindow - 1)
    model.appeared()
    // Hands-free pressed afresh rather than skipping over a dead latch.
    #expect(commands.sent.map(\.kind) == [.press, .press])
    #expect(model.unansweredPress == commands.sent.last?.id)
  }
}
