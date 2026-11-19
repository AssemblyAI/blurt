import Foundation
import Synchronization
import Testing

@testable import BlurtiOSCore

// Leaving the screen with a stop out (DESIGN.md › The two processes: leaving
// with a stop out), apart from the rest of the lifecycle so neither crowds
// the other.
extension KeyboardLifecycleTests {
  /// How many `keyboard` signals the app would have heard.
  nonisolated private final class Posts: Sendable {
    let count = Mutex(0)
    var seen: Int { count.withLock { $0 } }
  }

  @Test("leaving with a release of its own out: the command goes first, and presence holds until the app answers it")
  func leaveWaitsForStopAck() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.autoDictate = false
    let posts = Posts()
    let observer = DarwinObserver(name: BlurtShared.Signal.keyboard) { posts.count.withLock { $0 += 1 } }
    defer { withExtendedLifetime(observer) {} }
    let rig = KeyboardRig()
    let model = rig.model
    model.appeared()
    #expect(await eventually { posts.seen == 1 })
    let dictation = rig.latchRecording()
    model.disappeared()
    #expect(rig.commands.sent.map(\.kind) == [.press, .release])
    #expect(model.leaving != nil)
    // The record still says on screen and the signal is unsent: the app's
    // watchdog, asked now, finds the owner there and releases nothing.
    #expect(SharedStore.keyboardPresence?.onScreen == true)
    #expect(SharedStore.keyboardSeenAt != nil)
    #expect(!(await eventually(.milliseconds(300)) { posts.seen > 1 }))
    #expect(
      !OwnerWatchdog.shouldRelease(
        inFlight: DictationRef(id: dictation, ownerProcessID: KeyboardProcess.id),
        presence: SharedStore.keyboardPresence, now: Date()))
    rig.answer(.stopped(dictation))
    #expect(model.leaving == nil)
    #expect(SharedStore.keyboardPresence?.onScreen == false)
    #expect(SharedStore.keyboardSeenAt == nil)
    #expect(await eventually { posts.seen == 2 })
  }

  @Test("with no answer, presence ends at the grace — the stop's own deadline — and not before")
  func leaveGrace() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.autoDictate = false
    let rig = KeyboardRig()
    let model = rig.model
    model.appeared()
    rig.latchRecording()
    model.disappeared()
    // The stop's own deadline tick aside, so the grace alone is what ends it.
    model.cancelTicks()
    #expect(SharedStore.keyboardPresence?.onScreen == true)
    #expect(!(await eventually(.milliseconds(500)) { SharedStore.keyboardPresence?.onScreen == false }))
    #expect(
      await eventually(.seconds(KeyboardModel.leaveGrace + 1)) { SharedStore.keyboardPresence?.onScreen == false })
    #expect(model.leaving == nil && SharedStore.keyboardSeenAt == nil)
  }

  @Test("back on screen before the answer, the leave is dropped; detached with one pending, it lands at once")
  func leaveDroppedOrForced() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.autoDictate = false
    let rig = KeyboardRig()
    let model = rig.model
    model.appeared()
    let dictation = rig.latchRecording()
    model.disappeared()
    model.appeared()
    #expect(model.leaving == nil)
    rig.answer(.stopped(dictation))
    #expect(SharedStore.keyboardPresence?.onScreen == true)
    #expect(SharedStore.keyboardSeenAt != nil)
    // Nothing will be there to write the record later than the detach.
    let again = KeyboardRig()
    again.model.appeared()
    again.latchRecording()
    again.model.disappeared()
    #expect(again.model.leaving != nil)
    again.model.detach()
    #expect(again.model.leaving == nil)
    #expect(SharedStore.keyboardPresence?.onScreen == false)
  }
}
