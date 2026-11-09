import Foundation
import Testing

@testable import BlurtiOS
@testable import BlurtiOSCore

// MARK: - The heartbeat, from the launch on
//
// The lease is renewed for as long as the process lives, in every state of
// the window: a closed record is renewed with its reason kept, so the keyboard
// reads an app that is alive as off and never as suspended, and the sequence
// climbs through the beats into the next window.

extension ListeningWindowTests {
  @Test("start writes the launch record and beats from then on: the closed record renewed, its reason kept")
  func startBeatsWhileClosed() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig()
    rig.window.start()
    guard let launched = rig.state else {
      Issue.record("start published nothing")
      return
    }
    #expect(launched.window == .closed && launched.sequence == 0 && launched.reason == .sessionOff)
    #expect(launched.launchID == rig.window.launchID)
    #expect(SharedStore.listeningState == launched)
    // The heartbeat takes its first turn before the clock moves.
    await rig.clock.waitUntilSleeping(for: .seconds(SharedStore.appHeartbeatInterval))
    rig.clock.advance(by: .seconds(SharedStore.appHeartbeatInterval))
    #expect(await until { rig.state?.sequence == 1 })
    guard let beat = rig.state else { return }
    #expect(beat.window == .closed && beat.reason == .sessionOff && !beat.micLive)
    #expect(beat.leaseUntil > launched.leaseUntil && beat.leaseUntil > Date())
    #expect(beat.notReady(now: Date()) == .sessionOff, "off, never suspended")
    #expect(SharedStore.listeningState == beat)
    #expect(rig.source.opened == 0 && rig.audio.activated == 0, "a beat opens nothing")
  }

  @Test("a refused open's reason survives the beats, and the next window's records follow them in sequence")
  func beatsKeepTheReasonAndTheOrder() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig()
    rig.window.start()
    rig.app.state = .background
    rig.window.open()
    #expect(await until { rig.state?.reason == .needsForeground })
    let refused = rig.state?.sequence ?? 0
    rig.clock.advance(by: .seconds(SharedStore.appHeartbeatInterval))
    #expect(await until { (rig.state?.sequence ?? 0) > refused })
    #expect(rig.state?.window == .closed && rig.state?.reason == .needsForeground)
    let renewed = rig.state?.sequence ?? 0
    rig.app.state = .active
    #expect(await rig.opened())
    #expect((rig.state?.sequence ?? 0) > renewed, "the window's records come after the beats")
    #expect(rig.state?.micLive == true)
    // Through the window's life the machine beats; after it, the record it left.
    rig.clock.advance(by: .seconds(SharedStore.appHeartbeatInterval))
    #expect(await until { rig.state?.micLive == true && (rig.state?.sequence ?? 0) > renewed + 2 })
    #expect(await rig.closed())
    let closed = rig.state?.sequence ?? 0
    rig.clock.advance(by: .seconds(SharedStore.appHeartbeatInterval))
    #expect(await until { (rig.state?.sequence ?? 0) > closed })
    #expect(rig.state?.window == .closed && rig.state?.reason == .sessionOff && rig.state?.micLive == false)
    #expect(rig.state?.notReady(now: Date()) == .sessionOff)
  }

  @Test("start is once: a second call neither republishes nor doubles the beat")
  func startOnce() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = WindowRig()
    rig.window.start()
    rig.window.start()
    #expect(rig.state?.sequence == 0)
    await rig.clock.waitUntilSleeping(for: .seconds(SharedStore.appHeartbeatInterval))
    rig.clock.advance(by: .seconds(SharedStore.appHeartbeatInterval))
    #expect(await until { rig.state?.sequence == 1 })
    // The one heartbeat parks again; a second would have beaten too.
    await rig.clock.waitUntilSleeping(for: .seconds(SharedStore.appHeartbeatInterval))
    #expect(rig.state?.sequence == 1, "one heartbeat, one beat")
    #expect(rig.clock.sleepingFor == [.seconds(SharedStore.appHeartbeatInterval)], "one sleeper")
  }
}
