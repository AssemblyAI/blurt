import BlurtEngine
import Foundation
import Testing

@testable import BlurtiOSCore

@Suite("Keyboard model: the mic, the phase and results", .serialized)
@MainActor
struct KeyboardModelProtocolTests {
  /// This test's own App Group: a fresh scratch suite each test, since
  /// Swift Testing runs every test on a new instance of the suite.
  let store = SharedStore.scratch()

  @Test("a tap presses and latches; answered, the next tap releases the dictation by its id")
  func tapThenTap() {
    let rig = KeyboardRig(store: store)
    let model = rig.model
    let commands = rig.commands
    model.tapMic()
    #expect(commands.sent.map(\.kind) == [.press])
    #expect(!model.gate.isIdle)
    let dictation = UUID()
    rig.answer(.started(dictation))
    let release = rig.tapToStop(dictation)
    #expect(commands.sent.map(\.kind) == [.press, .release])
    #expect(release?.dictationID == dictation)
  }

  @Test("a dictation started elsewhere, named by the app, latches on the finger so one tap stops it")
  func latchOnInFlight() {
    let rig = KeyboardRig(store: store)
    let model = rig.model
    let commands = rig.commands
    let dictation = UUID()
    model.apply(snapshot(.recording, dictation: dictation))
    #expect(model.gate.isIdle)
    model.tapMic()
    #expect(commands.sent.map(\.kind) == [.release])
    #expect(commands.sent.last?.dictationID == dictation)
  }

  @Test("a press while transcribing is refused rather than dropped by the engine")
  func noPressWhileProcessing() {
    let rig = KeyboardRig(store: store)
    let model = rig.model
    let commands = rig.commands
    model.apply(snapshot(.processing, dictation: UUID()))
    model.tapMic()
    #expect(commands.sent.isEmpty)
    #expect(model.gate.isIdle)
  }

  @Test(
    "leaving the screen releases a recording this keyboard owns, and ends its presence once that is answered")
  func disappearEndsDictation() {
    let rig = KeyboardRig(store: store)
    let model = rig.model
    let commands = rig.commands
    model.appeared()
    let dictation = rig.latchRecording()
    model.disappeared()
    #expect(commands.sent.map(\.kind) == [.press, .release])
    #expect(commands.sent.last?.dictationID == dictation)
    // Presence holds behind the release (DESIGN.md: leaving with a stop
    // out), so the app's watchdog has nothing to release a second time.
    #expect(store.keyboardSeenAt != nil)
    #expect(store.keyboardPresence?.onScreen == true)
    // The gate comes up with the app's answer, and presence ends with it.
    rig.answer(.stopped(dictation))
    #expect(model.gate.isIdle)
    #expect(store.keyboardSeenAt == nil)
    #expect(store.keyboardPresence?.onScreen == false)
  }

  @Test("a result is inserted once, only while fresh, only if addressed here")
  func results() {
    let rig = KeyboardRig(store: store)
    let model = rig.model
    let proxy = rig.proxy
    proxy.before = "Hi"
    func deliver(_ text: String, to recipient: String?, age: TimeInterval = 0) {
      store.write(
        DictationResult(id: UUID(), text: text, deliveredAt: Date().addingTimeInterval(-age), recipient: recipient),
        forKey: BlurtShared.Key.result
      )
    }
    deliver("one", to: nil)
    model.resultArrived()
    #expect(proxy.before == "Hi one")
    #expect(store.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
    deliver("two", to: nil, age: 20)
    model.resultArrived()
    #expect(proxy.before == "Hi one")
    deliver("three", to: "someone-else")
    model.resultArrived()
    #expect(proxy.before == "Hi one")
    deliver("four", to: KeyboardProcess.id)
    model.resultArrived()
    #expect(proxy.before == "Hi one four")
  }

  /// #346: the words were for the field the dictation was made in. Tapping
  /// into another while they are transcribed — iOS keeping this controller
  /// for it, or a new one coming up in the same process — must not move them.
  @Test("a result for another field in this process is left for the app to copy out")
  func resultForAnotherField() {
    let rig = KeyboardRig(store: store)
    let model = rig.model
    let proxy = rig.proxy
    let fieldA = proxy.documentIdentifier
    func deliver(_ text: String, controller: String?, document: UUID?) {
      store.write(
        DictationResult(
          id: UUID(),
          text: text,
          deliveredAt: Date(),
          recipient: KeyboardProcess.id,
          controllerID: controller,
          documentID: document
        ),
        forKey: BlurtShared.Key.result
      )
    }
    // The same controller, now over field B.
    proxy.documentIdentifier = UUID()
    deliver("for A", controller: model.controllerID, document: fieldA)
    model.resultArrived()
    #expect(proxy.before.isEmpty)
    // Not taken: the app sees it still there and copies it out at its timeout.
    #expect(store.read(DictationResult.self, forKey: BlurtShared.Key.result)?.text == "for A")
    // Another controller in this process — a new one for field B — leaves it too,
    // including on appearing, which looks for words that landed while away.
    let other = KeyboardRig(store: store, proxy: proxy)
    other.model.resultArrived()
    deliver("for A", controller: model.controllerID, document: nil)
    other.model.resultArrived()
    #expect(proxy.before.isEmpty)
    // Back over field A, the words go in.
    proxy.documentIdentifier = fieldA
    deliver("for A", controller: model.controllerID, document: fieldA)
    model.resultArrived()
    #expect(proxy.before == "for A")
    #expect(store.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
  }

  @Test("a result naming no field — an older app build — goes to whichever field is up")
  func resultForNoField() {
    #expect(
      DictationResult(id: UUID(), text: "x", deliveredAt: Date(), recipient: nil)
        .isFor(controllerID: "any", documentID: UUID()))
    let id = UUID()
    let onlyController = DictationResult(
      id: UUID(), text: "x", deliveredAt: Date(), recipient: nil, controllerID: "c", documentID: nil
    )
    #expect(onlyController.isFor(controllerID: "c", documentID: id))
    #expect(!onlyController.isFor(controllerID: "d", documentID: id))
  }

  @Test("the term field never claims a cursor move or a selection")
  func termFieldIgnoresCursorMoves() {
    let rig = KeyboardRig(store: store)
    let model = rig.model
    let proxy = rig.proxy
    proxy.before = "Hello wor"
    proxy.after = "ld"
    model.beginAddingTerm()
    // The cursor moved two to the right: both sides changed.
    proxy.before = "Hello world"
    proxy.after = ""
    model.contextChanged()
    #expect(model.termDraft?.isEmpty == true)
    #expect(proxy.before == "Hello world")
    // A selection appeared with the same growth.
    proxy.before = "Hello wor"
    proxy.after = "ld"
    model.beginAddingTerm()
    proxy.before = "Hello world"
    proxy.selected = "ld"
    model.contextChanged()
    #expect(model.termDraft?.isEmpty == true)
  }

  @Test("a selection with spaces around it is replaced with the spaces kept")
  func termReplaceKeepsSpaces() {
    let rig = KeyboardRig(store: store)
    let model = rig.model
    let proxy = rig.proxy
    proxy.before = "he said"
    proxy.selected = " riz "
    model.beginAddingTerm()
    #expect(model.termDraft == "riz")
    model.termType("z")
    model.saveTerm()
    #expect(proxy.before == "he said rizz ")
    #expect(store.keyTerms == ["rizz"])
  }
}
