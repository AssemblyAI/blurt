import BlurtEngine
import Foundation
import Testing
import UIKit

@testable import BlurtiOSCore

@Suite("The two-process contract", .serialized)
@MainActor
struct ProtocolTests {
  @Test("the key-term key is the engine's own, so the app's and the keyboard's readers agree")
  func keyTermsKey() {
    #expect(SharedStore.keyTermsKey == KeyTermsStore.defaultsKey)
  }

  @Test("listening is the record's word: an open window with a live mic and a fresh lease")
  func isListening() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let now = Date()
    KeyboardRig.listening(true, now: now)
    #expect(SharedStore.isListening(now: now))
    // Closed or interrupted reads false however fresh the lease.
    KeyboardRig.record(.closed, reason: .sessionOff)
    #expect(!SharedStore.isListening(now: now))
    KeyboardRig.record(.interrupted, reason: .interrupted)
    #expect(!SharedStore.isListening(now: now))
    // Open with the mic not live, or with the lease lapsed, reads false too.
    KeyboardRig.record(.open, micLive: false)
    #expect(!SharedStore.isListening(now: now))
    KeyboardRig.record(.open, micLive: true, age: ListeningState.lease + 1)
    #expect(!SharedStore.isListening(now: now))
    // The record decides whenever there is one; the older keys answer for a
    // build that has not written it.
    SharedStore.listeningState = nil
    SharedStore.listeningUntil = now.addingTimeInterval(600)
    SharedStore.appSeenAt = now.addingTimeInterval(-2)
    #expect(SharedStore.isListening(now: now))
    SharedStore.appSeenAt = now.addingTimeInterval(-(SharedStore.presenceWindow + 1))
    #expect(!SharedStore.isListening(now: now))
  }

  @Test("the lease outlasts two missed app heartbeats and is never open-ended")
  func leaseRatio() {
    #expect(ListeningState.lease > 2 * SharedStore.appHeartbeatInterval)
    #expect(ListeningState(launchID: UUID(), sequence: 0, window: .open).leaseUntil < .distantFuture)
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
    let taker = takeResultShortly()
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
    let taker = takeResultShortly()
    try await injector.insert("on time", after: nil, windowTitle: nil)
    let taken = await taker.value
    #expect(taken?.text == "on time")
    #expect(taken?.recipient == "kb-1")
  }
}

/// Stands in for the keyboard: a moment after the app hands a result over, takes
/// it out of the store the way the keyboard's signal handler does.
private func takeResultShortly() -> Task<DictationResult?, Never> {
  Task {
    try? await Task.sleep(for: .milliseconds(300))
    let pending = SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result)
    SharedStore.remove(forKey: BlurtShared.Key.result)
    return pending
  }
}

@Suite("Keyboard model: the mic, the phase and results", .serialized)
@MainActor
struct KeyboardModelProtocolTests {

  @Test("a tap presses and latches; answered, the next tap releases the dictation by its id")
  func tapThenTap() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
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
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
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
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let commands = rig.commands
    model.apply(snapshot(.processing, dictation: UUID()))
    model.tapMic()
    #expect(commands.sent.isEmpty)
    #expect(model.gate.isIdle)
  }

  @Test("leaving the screen releases a recording this keyboard owns, and ends its presence once that is answered")
  func disappearEndsDictation() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let commands = rig.commands
    model.appeared()
    let dictation = rig.latchRecording()
    model.disappeared()
    #expect(commands.sent.map(\.kind) == [.press, .release])
    #expect(commands.sent.last?.dictationID == dictation)
    // Presence holds behind the release (DESIGN.md: leaving with a stop
    // out), so the app's watchdog has nothing to release a second time.
    #expect(SharedStore.keyboardSeenAt != nil)
    #expect(SharedStore.keyboardPresence?.onScreen == true)
    // The gate comes up with the app's answer, and presence ends with it.
    rig.answer(.stopped(dictation))
    #expect(model.gate.isIdle)
    #expect(SharedStore.keyboardSeenAt == nil)
    #expect(SharedStore.keyboardPresence?.onScreen == false)
  }

  @Test("a result is inserted once, only while fresh, only if addressed here")
  func results() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
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
    deliver("four", to: KeyboardProcess.id)
    model.resultArrived()
    #expect(proxy.before == "Hi one four")
  }

  @Test("delete right after a dictation takes all of it back, once; anywhere else it is an ordinary delete")
  func undoLastInsertion() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let proxy = rig.proxy
    func deliver(_ text: String) {
      SharedStore.write(
        DictationResult(id: UUID(), text: text, deliveredAt: Date(), recipient: nil),
        forKey: BlurtShared.Key.result)
      model.resultArrived()
    }
    // Nothing landed yet: nothing to take back.
    proxy.before = "Hi"
    #expect(!model.undoLastInsertion())
    #expect(proxy.before == "Hi")
    deliver("there friend")
    #expect(proxy.before == "Hi there friend")
    #expect(model.undoLastInsertion())
    #expect(proxy.before == "Hi")
    // Only once: the next delete is a character again.
    #expect(!model.undoLastInsertion())
    #expect(proxy.before == "Hi")

    // The keyboard's own edit after the dictation ends the undo.
    deliver("again")
    proxy.insertText("!")
    model.hostEdited()
    #expect(!model.undoLastInsertion())
    #expect(proxy.before == "Hi again!")

    // So does a caret that no longer sits at the dictation's end, or a selection.
    deliver("moved")
    proxy.before += "x"
    #expect(!model.undoLastInsertion())
    #expect(proxy.before == "Hi again! movedx")
    deliver("chosen")
    proxy.selected = "chosen"
    #expect(!model.undoLastInsertion())
    #expect(proxy.before == "Hi again! movedx chosen")
    proxy.selected = nil

    // Another field whose text happens to end the same way keeps its text.
    deliver("OK.")
    proxy.documentIdentifier = UUID()
    #expect(!model.undoLastInsertion())
    #expect(proxy.before == "Hi again! movedx chosen OK.")
    // Nor does the undo survive the keyboard leaving the screen.
    deliver("bye")
    model.disappeared()
    #expect(!model.undoLastInsertion())
    #expect(proxy.before == "Hi again! movedx chosen OK. bye")
  }

  @Test("with delete whole dictation off, delete after a dictation is an ordinary delete: the undo declines")
  func deleteAfterDictationIsOneCharacterWhenOff() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.deleteWholeDictation = false
    let rig = KeyboardRig()
    let model = rig.model
    let proxy = rig.proxy
    proxy.before = "Hi"
    SharedStore.write(
      DictationResult(id: UUID(), text: "there friend", deliveredAt: Date(), recipient: nil),
      forKey: BlurtShared.Key.result)
    model.resultArrived()
    #expect(proxy.before == "Hi there friend")
    // The handler then lets KeyboardKit delete one character, as any key.
    #expect(!model.undoLastInsertion())
    #expect(proxy.before == "Hi there friend")
    SharedStore.deleteWholeDictation = true
    #expect(model.undoLastInsertion())
    #expect(proxy.before == "Hi")
  }

  @Test("the term field never claims a cursor move or a selection")
  func termFieldIgnoresCursorMoves() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
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
    let rig = KeyboardRig()
    let model = rig.model
    let proxy = rig.proxy
    proxy.before = "he said"
    proxy.selected = " riz "
    model.beginAddingTerm()
    #expect(model.termDraft == "riz")
    model.termType("z")
    model.saveTerm()
    #expect(proxy.before == "he said rizz ")
    #expect(SharedStore.keyTerms == ["rizz"])
  }
}
