import Foundation
import Testing

@testable import BlurtiOS
@testable import BlurtiOSCore

/// The interpreter over fakes: what the window does to its source, its audio
/// session and its background tasks for each thing that happens, and the
/// record it leaves for the keyboard at every step. The rules themselves are
/// `ListeningWindowMachineTests`; this is the wiring.
@Suite("Listening window", .serialized)
@MainActor
struct ListeningWindowTests {
  @Test("open in front: the session up, the source opened, the record open with a live mic")
  func openInFront() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig()
    #expect(await rig.opened())
    let record = rig.state
    #expect(record?.micLive == true)
    #expect(record?.launchID == rig.window.launchID)
    #expect(record?.windowUntil != nil)
    #expect(SharedStore.listeningState == record)
    #expect(SharedStore.isListening)
    #expect(rig.source.opened == 1)
    #expect(rig.audio.activated == 1)
    #expect(rig.idle.opened == 1)
    #expect(rig.window.isOn)
    #expect(rig.window.lastError == nil)
  }

  @Test("open in the background: refused with needsForeground; the source and the session are never touched")
  func openInBackground() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig()
    rig.app.state = .background
    rig.window.open()
    #expect(await until { rig.state?.reason == .needsForeground })
    #expect(rig.state?.window == .closed)
    #expect(rig.source.opened == 0)
    #expect(rig.audio.activated == 0)
    #expect(!rig.window.isOn)
    #expect(!SharedStore.isListening)
    // Inactive is not the background: a hop lands there, and iOS lets capture start.
    rig.app.state = .inactive
    #expect(await rig.opened())
  }

  @Test("a call releases the dictation in flight with its words and pauses the window under a background task")
  func interruptionBegan() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig()
    #expect(await rig.dictating())
    #expect(rig.idle.began == 1)
    #expect(await rig.interrupted())
    #expect(rig.endings == [true])
    #expect(rig.state?.micLive == false)
    #expect(rig.state?.reason == .interrupted)
    #expect(rig.tasks.begun == [ListeningWindow.interruptionTask])
    // The source's own word on the same interruption is nothing new.
    rig.source.eventSink.yield(.interrupted(reason: "audioDeviceInUseByAnotherClient"))
    try? await Task.sleep(for: .milliseconds(100))
    #expect(rig.endings == [true])
    #expect(rig.tasks.begun.count == 1)
  }

  @Test("the interruption's end resumes by polling the source, never by starting it from the background")
  func interruptionEnded() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig()
    await rig.opened()
    await rig.interrupted()
    rig.audio.sink.yield(.interruptionEnded(shouldResume: true))
    #expect(await until { rig.state?.window == .open })
    #expect(rig.source.held == 0)
    #expect(rig.source.opened == 1)
    #expect(rig.audio.activated == 2)
    #expect(rig.tasks.ended == [ListeningWindow.interruptionTask])
    #expect(rig.state?.micLive == true)
    #expect(SharedStore.isListening)
  }

  @Test("a source that does not come back stays interrupted; the next foreground starts it again")
  func resumeOnForeground() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig()
    await rig.opened()
    await rig.interrupted()
    rig.source.setOpen(false)
    rig.audio.sink.yield(.interruptionEnded(shouldResume: true))
    // The poll runs on the clock: ten steps of 50 ms.
    for _ in 0..<12 {
      try? await Task.sleep(for: .milliseconds(10))
      rig.clock.advance(by: ListeningWindow.resumePollStep)
    }
    #expect(await until { rig.state?.reason == .interrupted && rig.tasks.ended.count == 1 })
    #expect(rig.state?.window == .interrupted)
    #expect(rig.source.held == 0)
    rig.window.foregrounded(turnedOff: false)
    #expect(await until { rig.state?.window == .open })
    #expect(rig.source.held == 1)
    #expect(rig.idle.opened == 2)
  }

  @Test("a runtimeError from the source flips micLive off at once, with the mic busy as the reason")
  func runtimeError() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig()
    await rig.opened()
    rig.source.eventSink.yield(.runtimeError(code: -12782))
    #expect(await until { rig.state?.window == .interrupted })
    #expect(rig.state?.micLive == false)
    #expect(rig.state?.reason == .micBusy)
    #expect(!SharedStore.isListening)
    // No background task for a dead session: there is no call to wait out.
    #expect(rig.tasks.begun.isEmpty)
    // A beat says the same, however the idle mode reads the source.
    rig.source.setOpen(true)
    let sequence = rig.state?.sequence ?? 0
    rig.window.beat()
    #expect(await until { (rig.state?.sequence ?? 0) > sequence })
    #expect(rig.state?.micLive == false)
  }

  @Test("the lease is never distantFuture, and a beat renews it with the mic as the idle mode reads it")
  func lease() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig()
    rig.window.start()
    await rig.opened()
    guard let first = rig.state else { return }
    #expect(first.leaseUntil < Date().addingTimeInterval(ListeningState.lease + 1))
    #expect(first.leaseUntil > Date())
    rig.clock.advance(by: .seconds(SharedStore.appHeartbeatInterval))
    #expect(await until { (rig.state?.sequence ?? 0) > first.sequence })
    guard let beat = rig.state else { return }
    #expect(beat.leaseUntil >= first.leaseUntil)
    #expect(beat.leaseUntil < Date().addingTimeInterval(ListeningState.lease + 1))
    #expect(beat.micLive && beat.window == .open)
    // The source gone under the window: the next beat says so.
    rig.source.setOpen(false)
    rig.clock.advance(by: .seconds(SharedStore.appHeartbeatInterval))
    #expect(await until { (rig.state?.sequence ?? 0) > beat.sequence })
    #expect(rig.state?.micLive == false)
    #expect(rig.state?.window == .open)
  }

  @Test("a reopen during close: the source closes once and opens once more")
  func reopenDuringClose() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig(closeDelay: .milliseconds(200))
    await rig.opened()
    rig.window.close()
    rig.window.open()
    // The reopen goes through once the source has closed, so the second
    // open is what says it did.
    #expect(await until { rig.source.opened == 2 && rig.state?.window == .open })
    #expect(rig.source.closed == 1)
    #expect(rig.audio.activated == 2)
    #expect(rig.audio.deactivated == 1)
  }

  @Test("windowMinutesChanged reschedules the expiry: the shorter window ends on the clock with its words kept")
  func windowMinutesChanged() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.windowMinutes = 15
    let rig = WindowRig()
    await rig.opened()
    guard let long = rig.state?.windowUntil else {
      Issue.record("no end on a 15-minute window")
      return
    }
    SharedStore.windowMinutes = 1
    rig.window.windowMinutesChanged()
    #expect(await until { (rig.state?.windowUntil ?? .distantFuture) < long })
    rig.clock.advance(by: .seconds(61))
    #expect(await until { rig.state?.window == .closed })
    #expect(rig.state?.reason == .sessionOff)
    #expect(rig.source.closed == 1)
    #expect(rig.audio.deactivated == 1)
    #expect(rig.idle.closing == 1)
    #expect(rig.endings.isEmpty)
    #expect(!rig.window.isOn)
  }

  @Test("the user's stop cancels the dictation in flight and stands the session down")
  func stop() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig()
    #expect(await rig.dictating())
    rig.window.close()
    #expect(await until { rig.state?.window == .closed })
    #expect(rig.endings == [false])
    #expect(rig.source.closed == 1)
    #expect(rig.audio.deactivated == 1)
    #expect(rig.idle.closing == 1)
    #expect(rig.idle.ended == 0, "the window's close, not a phase, ended it")
  }

  @Test("a press's failed start is the window's news: a refused background start waits for the foreground")
  func captureFailed() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig()
    await rig.opened()
    rig.window.captureFailed(reason: .sessionOff)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(rig.state?.window == .open, "the session being off is no news")
    rig.window.captureFailed(reason: .needsForeground)
    #expect(await until { rig.state?.window == .interrupted })
    #expect(rig.state?.reason == .needsForeground)
    #expect(rig.tasks.begun.isEmpty)
    rig.window.foregrounded(turnedOff: false)
    #expect(await until { rig.state?.window == .open })
    #expect(rig.source.held == 1)
  }

  @Test("the idle mode's report reaches the record: parked under the keeper, or the source lost")
  func idleReports() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig()
    await rig.opened()
    #expect(rig.idle.generation == 1, "armed for the first window")
    rig.idle.report?(.idleChanged(.pip), rig.idle.generation)
    #expect(await until { rig.state?.idle == .pip })
    #expect(rig.state?.window == .open)
    rig.idle.report?(.sourceDied(.needsForeground), rig.idle.generation)
    #expect(await until { rig.state?.window == .interrupted })
    #expect(rig.state?.reason == .needsForeground)
  }
}
