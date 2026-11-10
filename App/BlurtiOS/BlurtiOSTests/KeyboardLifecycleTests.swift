import Foundation
import Testing
import UIKit

@testable import BlurtiOSCore

/// The keyboard's side of being on screen, over time: the presence record
/// and its heartbeat, the app's Darwin signals, the dwell that lets a notice
/// go and the error line it leaves, the host app leaving, the word list
/// handed to the app, and the responder walk that brings the app forward.
/// Leaving with a stop out is in `KeyboardLifecycleTests+Leave.swift`.
@Suite("Keyboard model: lifecycle and the app's signals", .serialized)
@MainActor
struct KeyboardLifecycleTests {

  /// Polls until `condition` holds or `timeout` passes; true when it held.
  func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  @Test("on screen, the keyboard writes its presence record and the older keys, and beats; gone, it says so")
  func heartbeat() async throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.autoDictate = false
    let model = KeyboardRig().model
    model.appeared()
    let record = try #require(SharedStore.keyboardPresence)
    #expect(record.processID == KeyboardProcess.id && record.controllerID == model.controllerID)
    #expect(record.onScreen && record.pid == KeyboardModel.pid && record.isFresh())
    #expect(SharedStore.keyboardInstance == KeyboardProcess.id)
    #expect(SharedStore.keyboardSeenAt != nil)
    // The heartbeat's first beat lands on its own.
    SharedStore.keyboardSeenAt = nil
    #expect(await eventually { SharedStore.keyboardSeenAt != nil })
    model.disappeared()
    #expect(SharedStore.keyboardPresence?.onScreen == false)
    #expect(SharedStore.keyboardPresence?.processID == KeyboardProcess.id)
    #expect(SharedStore.keyboardSeenAt == nil)
  }

  @Test("leaving never clears another process's record, nor another controller's in this one, nor the older key")
  func presenceCompareAndWrite() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.autoDictate = false
    let model = KeyboardRig().model
    model.appeared()
    let other = KeyboardPresenceRecord(processID: "other-process", controllerID: "c", pid: 1, onScreen: true)
    SharedStore.writeKeyboardPresence(other)
    model.disappeared()
    #expect(SharedStore.keyboardPresence?.processID == "other-process")
    #expect(SharedStore.keyboardPresence?.onScreen == true)
    #expect(SharedStore.keyboardSeenAt != nil, "the older key is the record's, and the record is theirs")
    let sibling = KeyboardPresenceRecord(
      processID: KeyboardProcess.id, controllerID: "the-next-field", pid: KeyboardModel.pid, onScreen: true)
    SharedStore.writeKeyboardPresence(sibling)
    model.disappeared()
    #expect(SharedStore.keyboardPresence?.controllerID == "the-next-field")
    #expect(SharedStore.keyboardPresence?.onScreen == true)
    #expect(SharedStore.keyboardSeenAt != nil)
    // The store's own rule: a write over another process's record, owned, is refused.
    #expect(!SharedStore.writeKeyboardPresence(model.presence(onScreen: false), ifOwnedBy: "someone-else"))
    #expect(SharedStore.keyboardPresence?.onScreen == true)
  }

  @Test("attached to its controller, the keyboard follows the app's phase, result, state and ack signals")
  func darwinSignals() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let proxy = FakeProxy()
    proxy.before = "Hi"
    let rig = KeyboardRig(proxy: proxy)
    let model = rig.model
    let controller = UIInputViewController(nibName: nil, bundle: nil)
    model.attach(to: controller)
    SharedStore.write(snapshot(.recording), forKey: BlurtShared.Key.phase)
    SharedStore.post(BlurtShared.Signal.phase)
    #expect(await eventually { model.snapshot.state == .recording })
    SharedStore.write(
      DictationResult(id: UUID(), text: "there", deliveredAt: Date(), recipient: nil), forKey: BlurtShared.Key.result)
    SharedStore.post(BlurtShared.Signal.result)
    #expect(await eventually { proxy.before == "Hi there" })
    // The record closing reaches the model and the line.
    KeyboardRig.listening(false)
    SharedStore.post(BlurtShared.Signal.state)
    #expect(await eventually { !model.isListening && model.statusLine?.text == VoiceNotice.Copy.tapToOpen })
    KeyboardRig.listening(true)
    SharedStore.post(BlurtShared.Signal.state)
    #expect(await eventually { model.isListening })
    // A press answered over the ack signal.
    model.apply(snapshot(.idle))
    model.tapMic()
    guard let press = rig.lastPress else { return }
    let dictation = UUID()
    SharedStore.acknowledge(CommandAck(commandID: press.id, launchID: KeyboardRig.launch, outcome: .started(dictation)))
    #expect(await eventually { model.handshake.dictationID == dictation })
  }

  @Test("detached, nothing reaches the model: no observers, no heartbeat, no ticks, no controller")
  func detach() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.autoDictate = false
    let model = KeyboardRig().model
    // Up first, then attached: a controller outside a keyboard extension has
    // no Full Access to read, and the appearance would take its word for it.
    model.appeared()
    let controller = UIInputViewController(nibName: nil, bundle: nil)
    model.attach(to: controller)
    model.tapMic()
    #expect(!model.observers.isEmpty && model.heartbeat != nil && !model.ticks.isEmpty)
    model.detach()
    #expect(model.observers.isEmpty && model.heartbeat == nil && model.ticks.isEmpty && model.controller == nil)
    SharedStore.write(snapshot(.recording), forKey: BlurtShared.Key.phase)
    SharedStore.post(BlurtShared.Signal.phase)
    #expect(!(await eventually(.milliseconds(300)) { model.snapshot.state == .recording }))
  }

  @Test("a notice lets go after its dwell, and a second read of the same snapshot does not bring it back")
  func noticeDwell() async throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let model = KeyboardRig().model
    let pasted = snapshot(.pasted)
    let dwell = try #require(pasted.noticeDwellSeconds)
    model.apply(pasted)
    #expect(model.snapshot.state == .pasted)
    #expect(await eventually(.seconds(dwell + 2)) { model.snapshot.state == .idle })
    model.apply(pasted)
    #expect(model.snapshot.state == .idle)
    // A new notice is not the one let go of.
    model.apply(snapshot(.copied))
    #expect(model.snapshot.state == .copied)
  }

  @Test("an error's line outlives the ring's dwell and goes on the next tap")
  func heldError() async throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let model = KeyboardRig().model
    let error = snapshot(.error, reason: .micSilent)
    let dwell = try #require(error.noticeDwellSeconds)
    model.apply(error)
    #expect(model.heldError == error)
    #expect(model.statusLine?.text == VoiceNotice.Copy.micSilent)
    #expect(await eventually(.seconds(dwell + 2)) { model.snapshot.state == .idle })
    #expect(model.statusLine?.text == VoiceNotice.Copy.micSilent)
    #expect(model.voiceState.glyph == nil)
    model.micDown()
    #expect(model.heldError == nil)
  }

  @Test("the host app leaving ends a dictation this keyboard owns: a recording released, a mic coming up cancelled")
  func hostLeaving() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let recording = KeyboardRig()
    let dictation = recording.latchRecording()
    recording.model.hostLeaving()
    #expect(recording.commands.sent.map(\.kind) == [.press, .release])
    #expect(recording.commands.sent.last?.dictationID == dictation)
    let connecting = KeyboardRig()
    connecting.model.tapMic()
    let coming = UUID()
    connecting.answer(.started(coming))
    connecting.model.hostLeaving()
    #expect(connecting.commands.sent.map(\.kind) == [.press, .cancel])
    #expect(connecting.commands.sent.last?.dictationID == coming)
    // Words being made, another keyboard's dictation, and a press unanswered
    // are left to the app and its watchdog.
    let processing = KeyboardRig()
    let made = processing.latchRecording()
    processing.model.apply(snapshot(.processing, dictation: made))
    processing.model.hostLeaving()
    #expect(processing.commands.sent.map(\.kind) == [.press])
    let foreign = KeyboardRig()
    foreign.model.apply(snapshot(.recording, dictation: UUID()))
    foreign.model.micDown()
    foreign.model.hostLeaving()
    #expect(foreign.commands.sent.isEmpty)
    let pressing = KeyboardRig()
    pressing.model.tapMic()
    pressing.model.hostLeaving()
    #expect(pressing.commands.sent.map(\.kind) == [.press])
  }

  @Test("the saved check clears after its dwell and takes the chip for that word with it")
  func termSavedDwell() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let proxy = FakeProxy()
    proxy.selected = "Rizz"
    let model = KeyboardRig(proxy: proxy).model
    model.contextChanged()
    #expect(model.selectedTerm == "Rizz")
    model.addSelectedTerm()
    #expect(model.termSavedAt != nil)
    #expect(SharedStore.keyTerms == ["Rizz"])
    #expect(await eventually(.seconds(KeyboardModel.termNoticeDwell + 2)) { model.termSavedAt == nil })
    #expect(model.selectedTerm == nil)
    #expect(model.dismissedSelection == "Rizz")
  }

  @Test("the phone's word list reaches the app: written, stamped, and only re-read once it is old")
  func lexicon() throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let entries = [
      LexiconEntry(userInput: "Neil Bisht", documentText: "Neil Bisht"),
      LexiconEntry(userInput: "omw", documentText: "On my way!"),
    ]
    KeyboardModel.store(entries)
    let stored = SharedStore.read([LexiconEntry].self, forKey: BlurtShared.Key.lexicon)
    #expect(stored?.map(\.documentText) == ["Neil Bisht", "On my way!"])
    #expect(stored?.map(\.isName) == [true, false])
    let refreshed = try #require(SharedStore.lexiconRefreshedAt)
    #expect(Date().timeIntervalSince(refreshed) < 5)
  }

  @Test("opening the app walks the responder chain to the application: setup without Full Access, start with it")
  func openApp() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let model = KeyboardModel()
    // No controller: nothing to walk.
    var opened: [URL] = []
    model.urlOpener = { opened.append($1) }
    model.tapMic()
    #expect(opened.isEmpty)
    // A controller on screen: its chain ends at the application.
    let controller = UIInputViewController(nibName: nil, bundle: nil)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    model.controller = controller
    // No Full Access: the tap that would have dictated opens Blurt's setup.
    #expect(model.statusLine == VoiceNotice.Line(text: VoiceNotice.Copy.fullAccess, tapOpens: .setup))
    model.tapMic()
    #expect(opened == [BlurtShared.setupURL(need: BlurtShared.fullAccessNeed)])
    #expect(opened.first?.absoluteString == "\(BlurtShared.urlScheme)://\(BlurtShared.setupHost)?need=fullAccess")
    // Full Access and no record: the tap opens Blurt to start, saying why.
    model.hasFullAccess = true
    model.tapMic()
    #expect(opened.last == BlurtShared.startURL(reason: .sessionOff))
    #expect(opened.last?.absoluteString == "\(BlurtShared.urlScheme)://\(BlurtShared.startHost)?reason=sessionOff")
  }
}
