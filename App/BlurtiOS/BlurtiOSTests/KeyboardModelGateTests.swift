import Foundation
import Testing
import UIKit

@testable import BlurtiOS

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
}
