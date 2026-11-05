import BlurtEngine
import Foundation
import Testing
import UIKit

@testable import BlurtiOS
@testable import BlurtiOSCore

/// The way back after the keyboard's hop: when the coordinator asks iOS for
/// the host app, and when it does not (`HopReturn`, `HostReturn`).
@Suite("Dictation coordinator: the hop's return", .serialized)
@MainActor
struct DictationCoordinatorReturnTests {
  static let messages = "com.apple.MobileSMS"

  final class Returns {
    var hosts: [String] = []
  }

  struct Bench {
    let coordinator: DictationCoordinator
    let rig: WindowRig
    let returns: Returns
  }

  /// A coordinator that believes the app is in `state` when a URL lands, and
  /// records every host it asks iOS for.
  func make(state: UIApplication.State = .background) -> Bench {
    let rig = WindowRig()
    let returns = Returns()
    let coordinator = DictationCoordinator(
      apiKey: APIKeyModel(keyStore: InMemoryAPIKeyStore()), window: rig.window,
      transcriber: StubTranscriber(text: "hello"), clock: rig.clock, appState: { state },
      hostReturner: { host in
        returns.hosts.append(host)
        return true
      })
    coordinator.start()
    return Bench(coordinator: coordinator, rig: rig, returns: returns)
  }

  @Test("a hop from another app goes back to it as soon as the window is open under a held mic")
  func returnsWhenOpen() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let bench = make()
    let (coordinator, rig, returns) = (bench.coordinator, bench.rig, bench.returns)
    coordinator.handle(BlurtShared.startURL(reason: .sessionOff, host: Self.messages))
    #expect(coordinator.returnHost == Self.messages)
    #expect(coordinator.startedFromKeyboard)
    #expect(returns.hosts.isEmpty, "not before the window is open")
    await rig.opened()
    #expect(returns.hosts == [Self.messages])
    #expect(coordinator.returnHost == nil && coordinator.returnCap == nil)
    #expect(!coordinator.startedFromKeyboard, "the hint is moot once the app has gone back")
    // The window's later records ask nothing more.
    await rig.dictating()
    #expect(returns.hosts == [Self.messages])
  }

  @Test("no return when the hop came with no host, from Blurt's own box, or with the app already in front")
  func noReturn() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let bench = make()
    let (coordinator, rig, returns) = (bench.coordinator, bench.rig, bench.returns)
    coordinator.handle(BlurtShared.startURL(reason: .sessionOff))
    #expect(coordinator.returnHost == nil)
    coordinator.handle(BlurtShared.startURL(reason: .sessionOff, host: Bundle.main.bundleIdentifier ?? "blurt"))
    #expect(coordinator.returnHost == nil)
    await rig.opened()
    #expect(returns.hosts.isEmpty)

    let second = make(state: .active)
    let (active, activeRig, activeReturns) = (second.coordinator, second.rig, second.returns)
    active.handle(BlurtShared.startURL(reason: .sessionOff, host: Self.messages))
    #expect(active.returnHost == nil && !active.startedFromKeyboard)
    await activeRig.opened()
    #expect(activeReturns.hosts.isEmpty)
  }

  @Test("with a keeper expected, the return waits for the keeper's report")
  func waitsForKeeper() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let bench = make()
    let (coordinator, rig, returns) = (bench.coordinator, bench.rig, bench.returns)
    coordinator.expectsKeeper = true
    coordinator.handle(BlurtShared.startURL(reason: .sessionOff, host: Self.messages))
    await rig.opened()
    #expect(returns.hosts.isEmpty, "open, but the keeper is not up")
    #expect(coordinator.returnCap != nil, "the cap is armed")
    rig.idle.report?(.idleChanged(.pip), rig.idle.generation)
    #expect(await until { returns.hosts == [Self.messages] })
    #expect(coordinator.returnCap == nil, "the cap stands down")
  }

  @Test("with a keeper expected but silent, the return comes at the cap")
  func returnsAtCap() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let bench = make()
    let (coordinator, rig, returns) = (bench.coordinator, bench.rig, bench.returns)
    coordinator.expectsKeeper = true
    coordinator.handle(BlurtShared.startURL(reason: .sessionOff, host: Self.messages))
    await rig.opened()
    #expect(returns.hosts.isEmpty)
    rig.clock.advance(by: .seconds(BlurtShared.hopReturnCap))
    #expect(await until { returns.hosts == [Self.messages] })
    #expect(coordinator.returnHost == nil)
  }

  @Test("the user leaving first, or the window closing before it opened, cancels the return")
  func cancelled() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let bench = make()
    let (coordinator, rig, returns) = (bench.coordinator, bench.rig, bench.returns)
    coordinator.expectsKeeper = true
    coordinator.handle(BlurtShared.startURL(reason: .sessionOff, host: Self.messages))
    await rig.opened()
    coordinator.sceneLeft()
    #expect(coordinator.returnHost == nil && coordinator.returnCap == nil && !coordinator.startedFromKeyboard)
    rig.clock.advance(by: .seconds(BlurtShared.hopReturnCap))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(returns.hosts.isEmpty)

    // A window seen and then closed: the open did not hold.
    let later = make()
    let (second, secondRig, secondReturns) = (later.coordinator, later.rig, later.returns)
    second.expectsKeeper = true
    second.handle(BlurtShared.startURL(reason: .sessionOff, host: Self.messages))
    await secondRig.opened()
    await secondRig.closed()
    #expect(second.returnHost == nil)
    secondRig.clock.advance(by: .seconds(BlurtShared.hopReturnCap))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(secondReturns.hosts.isEmpty)
  }
}
