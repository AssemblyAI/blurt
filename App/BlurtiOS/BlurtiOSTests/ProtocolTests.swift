import BlurtEngine
import Foundation
import Testing
import UIKit

@testable import BlurtiOS

@Suite("The two-process contract", .serialized)
@MainActor
struct ProtocolTests {
  @Test("the key-term key is the engine's own, so the app's and the keyboard's readers agree")
  func keyTermsKey() {
    #expect(SharedStore.keyTermsKey == KeyTermsStore.defaultsKey)
  }

  @Test("listening needs both a live window and a live app")
  func isListening() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let now = Date()
    SharedStore.listeningUntil = now.addingTimeInterval(600)
    SharedStore.appSeenAt = now.addingTimeInterval(-2)
    #expect(SharedStore.isListening(now: now))
    SharedStore.appSeenAt = now.addingTimeInterval(-(SharedStore.presenceWindow + 1))
    #expect(!SharedStore.isListening(now: now))
    SharedStore.appSeenAt = now
    SharedStore.listeningUntil = now.addingTimeInterval(-1)
    #expect(!SharedStore.isListening(now: now))
  }

  @Test("the presence windows outlast two missed heartbeats")
  func presenceRatio() {
    #expect(SharedStore.presenceWindow > 2 * SharedStore.appHeartbeatInterval)
    #expect(SharedStore.presenceWindow > 2 * SharedStore.keyboardHeartbeatInterval)
  }

  @Test("addKeyTerm trims and refuses a duplicate in any case")
  func addKeyTerm() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    #expect(SharedStore.addKeyTerm(" Rizz "))
    #expect(!SharedStore.addKeyTerm("rizz"))
    #expect(!SharedStore.addKeyTerm("  "))
    #expect(SharedStore.keyTerms == ["Rizz"])
  }

  @Test("with no keyboard on screen the words go to the clipboard and the phase is the quiet one")
  func relayFallsBackToClipboard() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.keyboardSeenAt = nil
    UIPasteboard.general.string = ""
    let injector = KeyboardRelayInjector()
    await #expect(throws: BlurtError.noEditableTarget) {
      try await injector.insert("hello there", after: nil, windowTitle: nil)
    }
    #expect(UIPasteboard.general.string == "hello there")
    #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
  }

  @Test("a result the keyboard never takes is copied out after the delivery timeout")
  func relayTimesOut() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.keyboardSeenAt = Date()
    SharedStore.keyboardInstance = "kb-1"
    UIPasteboard.general.string = ""
    let injector = KeyboardRelayInjector()
    let started = Date()
    await #expect(throws: BlurtError.noEditableTarget) {
      try await injector.insert("late words", after: nil, windowTitle: nil)
    }
    #expect(Date().timeIntervalSince(started) >= KeyboardRelayInjector.deliveryTimeout - 0.5)
    #expect(UIPasteboard.general.string == "late words")
    #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
  }

  @Test("the words go back to the keyboard that pressed; another keyboard up in its place means the clipboard")
  func relayToPresser() async throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.keyboardSeenAt = Date()
    SharedStore.keyboardInstance = "kb-2"
    UIPasteboard.general.string = ""
    let elsewhere = KeyboardRelayInjector(presser: { "kb-1" })
    await #expect(throws: BlurtError.noEditableTarget) {
      try await elsewhere.insert("wrong app", after: nil, windowTitle: nil)
    }
    #expect(UIPasteboard.general.string == "wrong app")
    #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
    let same = KeyboardRelayInjector(presser: { "kb-2" })
    let taker = Task {
      try? await Task.sleep(for: .milliseconds(300))
      let pending = SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result)
      SharedStore.remove(forKey: BlurtShared.Key.result)
      return pending
    }
    try await same.insert("right app", after: nil, windowTitle: nil)
    #expect(await taker.value?.recipient == "kb-2")
  }

  @Test("a result taken by the keyboard counts as delivered")
  func relayDelivered() async throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.keyboardSeenAt = Date()
    SharedStore.keyboardInstance = "kb-1"
    let injector = KeyboardRelayInjector()
    let taker = Task {
      try? await Task.sleep(for: .milliseconds(300))
      let pending = SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result)
      SharedStore.remove(forKey: BlurtShared.Key.result)
      return pending
    }
    try await injector.insert("on time", after: nil, windowTitle: nil)
    let taken = await taker.value
    #expect(taken?.text == "on time")
    #expect(taken?.recipient == "kb-1")
  }
}

@Suite("Keyboard model: the mic, the phase and results", .serialized)
@MainActor
struct KeyboardModelProtocolTests {
  /// A keyboard that is ready to dictate, wired to a fake field and a
  /// capture of the commands it sends.
  struct Rig {
    let model: KeyboardModel
    let proxy: FakeProxy
    let commands: Commands
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
    return Rig(model: model, proxy: proxy, commands: commands)
  }

  final class Commands {
    var sent: [KeyboardCommand] = []
  }

  private func snapshot(_ state: PhaseSnapshot.State, level: Double = 0) -> PhaseSnapshot {
    PhaseSnapshot(state: state, message: nil, level: level, at: Date())
  }

  @Test("a tap presses and latches; the next tap releases")
  func tapThenTap() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    let model = rig.model
    let commands = rig.commands
    model.micDown()
    model.micUp()
    #expect(commands.sent.map(\.kind) == [.press])
    model.apply(snapshot(.recording))
    model.micDown()
    model.micUp()
    #expect(commands.sent.map(\.kind) == [.press, .release])
  }

  @Test("a dictation started elsewhere latches the gate, so one tap stops it")
  func latchOnInFlight() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    let model = rig.model
    let commands = rig.commands
    model.apply(snapshot(.recording))
    #expect(!model.gate.isIdle)
    model.micDown()
    model.micUp()
    #expect(commands.sent.map(\.kind) == [.release])
  }

  @Test("a press while transcribing is refused rather than dropped by the engine")
  func noPressWhileProcessing() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    let model = rig.model
    let commands = rig.commands
    model.apply(snapshot(.processing))
    model.micDown()
    model.micUp()
    #expect(commands.sent.isEmpty)
    #expect(model.gate.isIdle)
  }

  @Test("leaving the screen releases a latched recording and cancels anything earlier")
  func disappearEndsDictation() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    let model = rig.model
    let commands = rig.commands
    model.micDown()
    model.micUp()
    model.apply(snapshot(.recording))
    model.disappeared()
    #expect(commands.sent.map(\.kind) == [.press, .release])
    #expect(model.gate.isIdle)
    #expect(SharedStore.keyboardSeenAt == nil)
  }

  @Test("a result is inserted once, only while fresh, only if addressed here")
  func results() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    let model = rig.model
    let proxy = rig.proxy
    proxy.before = "Hi"
    func deliver(_ text: String, age: TimeInterval = 0, to recipient: String?) {
      SharedStore.write(
        DictationResult(id: UUID(), text: text, deliveredAt: Date().addingTimeInterval(-age), recipient: recipient),
        forKey: BlurtShared.Key.result)
    }
    deliver("one", to: nil)
    model.resultArrived()
    #expect(proxy.before == "Hi one")
    #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
    deliver("two", age: 20, to: nil)
    model.resultArrived()
    #expect(proxy.before == "Hi one")
    deliver("three", to: "someone-else")
    model.resultArrived()
    #expect(proxy.before == "Hi one")
    deliver("four", to: model.instanceID)
    model.resultArrived()
    #expect(proxy.before == "Hi one four")
  }

  @Test("the term field never claims a cursor move or a selection")
  func termFieldIgnoresCursorMoves() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    let model = rig.model
    let proxy = rig.proxy
    proxy.before = "Hello wor"
    proxy.after = "ld"
    model.beginAddingTerm()
    // The cursor moved two to the right: both sides changed.
    proxy.before = "Hello world"
    proxy.after = ""
    model.contextChanged()
    #expect(model.termDraft == "")
    #expect(proxy.before == "Hello world")
    // A selection appeared with the same growth.
    proxy.before = "Hello wor"
    proxy.after = "ld"
    model.beginAddingTerm()
    proxy.before = "Hello world"
    proxy.selected = "ld"
    model.contextChanged()
    #expect(model.termDraft == "")
  }

  @Test("a selection with spaces around it is replaced with the spaces kept")
  func termReplaceKeepsSpaces() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    let model = rig.model
    let proxy = rig.proxy
    proxy.before = "he said"
    proxy.selected = " riz "
    model.beginAddingTerm()
    #expect(model.termDraft == "riz")
    model.type("z")
    model.saveTerm()
    #expect(proxy.before == "he said rizz ")
    #expect(SharedStore.keyTerms == ["rizz"])
  }

  @Test("shift follows the field: words, all characters, none")
  func shiftModes() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = ready()
    let model = rig.model
    let proxy = rig.proxy
    proxy.before = "hello "
    proxy.autocapitalizationType = .words
    model.contextChanged()
    #expect(model.shifted)
    proxy.before = "hello w"
    model.contextChanged()
    #expect(!model.shifted)
    proxy.autocapitalizationType = .allCharacters
    model.contextChanged()
    #expect(model.shifted)
    proxy.autocapitalizationType = .none
    model.shifted = false
    proxy.before = ""
    model.contextChanged()
    #expect(!model.shifted)
  }

  @Test("number fields open on the symbols page")
  func symbolsForNumbers() {
    #expect(KeyboardModel.wantsSymbols(.numberPad))
    #expect(KeyboardModel.wantsSymbols(.phonePad))
    #expect(KeyboardModel.wantsSymbols(.decimalPad))
    #expect(!KeyboardModel.wantsSymbols(.default))
    #expect(!KeyboardModel.wantsSymbols(nil))
  }
}
