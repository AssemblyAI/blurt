import Testing

@testable import BlurtiOS
@testable import BlurtiOSCore

// MARK: - One window after another
//
// What the window keeps apart across a close and a reopen: the idle mode's
// reports, which name the window they were made for; the audio session's
// interruption, which a Stop during a call must not carry over; and the hop
// over an interrupted window, which waits for the idle mode to let go before
// the next source opens.

extension ListeningWindowTests {
  @Test("an idle report for the window before changes nothing; one for the window that is up lands")
  func staleIdleReport() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig()
    await rig.opened()
    await rig.closed()
    await rig.opened()
    #expect(rig.idle.generation == 2)
    rig.idle.report?(.sourceDied(.needsForeground), 1)
    rig.idle.report?(.idleChanged(.pip), 1)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(rig.state?.window == .open && rig.state?.idle == .held && rig.state?.micLive == true)
    rig.idle.report?(.idleChanged(.pip), 2)
    #expect(await until { rig.state?.idle == .pip })
    #expect(rig.state?.window == .open)
  }

  @Test("a Stop during a call leaves no interruption on the next window's books: the source's own is news again")
  func interruptionResetByTheNextWindow() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig()
    await rig.opened()
    await rig.interrupted()
    await rig.closed()
    #expect(rig.audio.deactivated == 0, "the session stays active through the call")
    await rig.opened()
    rig.source.eventSink.yield(.interrupted(reason: "audioDeviceInUseByAnotherClient"))
    #expect(await until { rig.state?.window == .interrupted })
    #expect(rig.state?.reason == .interrupted)
  }

  @Test("a resume ends the interruption on the books even when the session's own end never came")
  func interruptionResetByResume() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig()
    await rig.opened()
    await rig.interrupted()
    rig.window.foregrounded(turnedOff: false)
    #expect(await until { rig.state?.window == .open })
    #expect(rig.source.held == 1)
    rig.source.eventSink.yield(.interrupted(reason: "audioDeviceInUseByAnotherClient"))
    #expect(await until { rig.state?.window == .interrupted })
  }

  @Test("a hop over an interrupted window waits for the idle mode to let go before the next source opens")
  func hopWaitsForTheIdleMode() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig(closingDelay: .milliseconds(200))
    await rig.opened()
    await rig.interrupted()
    rig.window.open()
    #expect(await until { rig.source.opened == 2 && rig.state?.window == .open })
    #expect(rig.ledger.lines == ["source.open", "idle.closing", "idle.closed", "source.close", "source.open"])
    #expect(rig.idle.closed == 1 && rig.idle.opened == 2 && rig.idle.generation == 2)
    #expect(rig.tasks.ended == [ListeningWindow.interruptionTask])
  }
}
