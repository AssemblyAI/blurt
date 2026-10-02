import BlurtEngine
import Foundation
import Testing
import UIKit

@testable import BlurtiOSCore

/// The keyboard's side of being on screen, over time: the presence heartbeat,
/// the app's Darwin signals, the dwell that lets a notice go, the release held
/// while the mic comes up, the word list handed to the app, and the responder
/// walk that brings the app forward.
@Suite("Keyboard model: lifecycle and the app's signals", .serialized)
@MainActor
struct KeyboardLifecycleTests {

  /// Polls until `condition` holds or `timeout` passes; true when it held.
  private func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  @Test("on screen, the keyboard tells the app it is there and which one it is; gone, it stops")
  func heartbeat() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.autoDictate = false
    let model = KeyboardRig().model
    model.appeared()
    #expect(await eventually { SharedStore.keyboardSeenAt != nil })
    #expect(SharedStore.keyboardInstance == model.instanceID)
    model.disappeared()
    #expect(SharedStore.keyboardSeenAt == nil)
  }

  @Test("attached to its controller, the keyboard follows the app's phase and result signals")
  func darwinSignals() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let proxy = FakeProxy()
    proxy.before = "Hi"
    let model = KeyboardRig(proxy: proxy).model
    let controller = UIInputViewController(nibName: nil, bundle: nil)
    model.attach(to: controller)
    SharedStore.write(snapshot(.recording), forKey: BlurtShared.Key.phase)
    SharedStore.post(BlurtShared.Signal.phase)
    #expect(await eventually { model.snapshot.state == .recording })
    SharedStore.write(
      DictationResult(id: UUID(), text: "there", deliveredAt: Date(), recipient: nil), forKey: BlurtShared.Key.result)
    SharedStore.post(BlurtShared.Signal.result)
    #expect(await eventually { proxy.before == "Hi there" })
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

  @Test("a release made while the mic is coming up is held for the first recording phase")
  func releaseWhileConnecting() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let commands = rig.commands
    model.micDown()
    model.apply(snapshot(.connecting))
    // Push-to-talk let go before the mic was up: the engine would drop a
    // release now, so it waits.
    model.perform(.stop)
    #expect(commands.sent.map(\.kind) == [.press])
    model.apply(snapshot(.recording))
    #expect(commands.sent.map(\.kind) == [.press, .release])
    #expect(model.gate.isIdle)
  }

  @Test("a held release is dropped when the mic never comes up")
  func heldReleaseDroppedOnFailure() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let model = rig.model
    let commands = rig.commands
    model.micDown()
    model.apply(snapshot(.connecting))
    model.perform(.stop)
    model.apply(snapshot(.error))
    model.apply(snapshot(.recording))
    #expect(commands.sent.map(\.kind) == [.press])
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

  @Test("opening the app walks the responder chain to the application and asks it for blurt://start")
  func openApp() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let model = KeyboardModel()
    // No controller: nothing to walk.
    var opened: [(UIApplication, URL)] = []
    model.urlOpener = { opened.append(($0, $1)) }
    model.openApp()
    #expect(opened.isEmpty)
    // A controller on screen: its chain ends at the application.
    let controller = UIInputViewController(nibName: nil, bundle: nil)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    model.controller = controller
    // Not ready (no Full Access): the tap that would have dictated opens Blurt.
    model.micDown()
    model.micUp()
    #expect(opened.count == 1)
    #expect(opened.first?.0 === UIApplication.shared)
    #expect(opened.first?.1.absoluteString == "\(BlurtShared.urlScheme)://\(BlurtShared.startHost)")
  }

  @Test("the mic's side comes from Settings unless a preview says otherwise")
  func micAlignment() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let model = KeyboardModel()
    #expect(model.micAlignment == .center)
    model.storedMicAlignment = .left
    #expect(model.micAlignment == .left)
    model.micAlignmentOverride = .right
    #expect(model.micAlignment == .right)
  }
}
