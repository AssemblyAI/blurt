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
  func startBeatsWhileClosed() async throws {
    let rig = WindowRig(store: store)
    rig.window.start()
    let launched = try #require(rig.state, "start published nothing")
    #expect(launched.window == .closed && launched.sequence == 0 && launched.reason == .sessionOff)
    #expect(launched.launchID == rig.window.launchID)
    #expect(store.listeningState == launched)
    // The heartbeat takes its first turn before the clock moves.
    #expect(await rig.beat())
    #expect(await until { rig.state?.sequence == 1 })
    guard let beat = rig.state else {
      return
    }
    #expect(beat.window == .closed && beat.reason == .sessionOff && !beat.micLive)
    #expect(beat.leaseUntil > launched.leaseUntil && beat.leaseUntil > rig.now)
    #expect(beat.notReady(now: rig.now) == .sessionOff, "off, never suspended")
    #expect(store.listeningState == beat)
    #expect(rig.source.opened == 0 && rig.audio.activated == 0, "a beat opens nothing")
  }

  @Test("a refused open's reason survives the beats, and the next window's records follow them in sequence")
  func beatsKeepTheReasonAndTheOrder() async {
    let rig = WindowRig(store: store)
    rig.window.start()
    rig.app.state = .background
    rig.window.open()
    #expect(await until { rig.state?.reason == .needsForeground })
    let refused = rig.state?.sequence ?? 0
    #expect(await rig.beat())
    #expect(await until { (rig.state?.sequence ?? 0) > refused })
    #expect(rig.state?.window == .closed && rig.state?.reason == .needsForeground)
    let renewed = rig.state?.sequence ?? 0
    rig.app.state = .active
    #expect(await rig.opened())
    #expect((rig.state?.sequence ?? 0) > renewed, "the window's records come after the beats")
    #expect(rig.state?.micLive == true)
    // Through the window's life the machine beats; after it, the record it left.
    #expect(await rig.beat())
    #expect(await until { rig.state?.micLive == true && (rig.state?.sequence ?? 0) > renewed + 2 })
    #expect(await rig.closed())
    let closed = rig.state?.sequence ?? 0
    #expect(await rig.beat())
    #expect(await until { (rig.state?.sequence ?? 0) > closed })
    #expect(rig.state?.window == .closed && rig.state?.reason == .sessionOff && rig.state?.micLive == false)
    #expect(rig.state?.notReady(now: rig.now) == .sessionOff)
  }

  @Test("start is once: a second call neither republishes nor doubles the beat")
  func startOnce() async {
    let rig = WindowRig(store: store)
    rig.window.start()
    rig.window.start()
    #expect(rig.state?.sequence == 0)
    #expect(await rig.beat())
    #expect(await until { rig.state?.sequence == 1 })
    // The one heartbeat parks again; a second would have beaten too.
    #expect(await until { rig.clock.sleepingFor.contains(.seconds(SharedStore.appHeartbeatInterval)) })
    #expect(rig.state?.sequence == 1, "one heartbeat, one beat")
    #expect(rig.clock.sleepingFor == [.seconds(SharedStore.appHeartbeatInterval)], "one sleeper")
  }
}
