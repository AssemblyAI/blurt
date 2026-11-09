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

  /// A hop from Messages, handled with `expectsKeeper` set, and the window
  /// then open: the point at which the return is decided.
  func hopped(expectsKeeper: Bool) async -> Bench {
    let bench = make()
    bench.coordinator.expectsKeeper = expectsKeeper
    bench.coordinator.handle(BlurtShared.startURL(reason: .sessionOff, host: Self.messages))
    await bench.rig.opened()
    return bench
  }

  @Test("a hop from another app goes back to it as soon as the window is open under a held mic")
  func returnsWhenOpen() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let bench = make()
    let coordinator = bench.coordinator
    coordinator.handle(BlurtShared.startURL(reason: .sessionOff, host: Self.messages))
    #expect(coordinator.returnHost == Self.messages)
    #expect(coordinator.startedFromKeyboard)
    #expect(bench.returns.hosts.isEmpty, "not before the window is open")
    await bench.rig.opened()
    #expect(bench.returns.hosts == [Self.messages])
    #expect(coordinator.returnHost == nil && coordinator.returnCap == nil)
    #expect(!coordinator.startedFromKeyboard, "the hint is moot once the app has gone back")
    // The window's later records ask nothing more.
    await bench.rig.dictating()
    #expect(bench.returns.hosts == [Self.messages])
  }

  @Test("no return when the hop came with no host, from Blurt's own box, or with the app already in front")
  func noReturn() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let bench = make()
    bench.coordinator.handle(BlurtShared.startURL(reason: .sessionOff))
    #expect(bench.coordinator.returnHost == nil)
    bench.coordinator.handle(
      BlurtShared.startURL(reason: .sessionOff, host: Bundle.main.bundleIdentifier ?? "blurt"))
    #expect(bench.coordinator.returnHost == nil)
    await bench.rig.opened()
    #expect(bench.returns.hosts.isEmpty)

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
    let bench = await hopped(expectsKeeper: true)
    #expect(bench.returns.hosts.isEmpty, "open, but the keeper is not up")
    #expect(bench.coordinator.returnCap != nil, "the cap is armed")
    bench.rig.idle.report?(.idleChanged(.pip), bench.rig.idle.generation)
    #expect(await until { bench.returns.hosts == [Self.messages] })
    #expect(bench.coordinator.returnCap == nil, "the cap stands down")
  }

  @Test("with a keeper expected but silent, the return comes at the cap")
  func returnsAtCap() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let bench = await hopped(expectsKeeper: true)
    #expect(bench.returns.hosts.isEmpty)
    bench.rig.clock.advance(by: .seconds(BlurtShared.hopReturnCap))
    #expect(await until { bench.returns.hosts == [Self.messages] })
    #expect(bench.coordinator.returnHost == nil)
  }

  @Test("the user leaving first, or the window closing before it opened, cancels the return")
  func cancelled() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let bench = await hopped(expectsKeeper: true)
    let coordinator = bench.coordinator
    coordinator.sceneLeft()
    #expect(coordinator.returnHost == nil && coordinator.returnCap == nil && !coordinator.startedFromKeyboard)
    bench.rig.clock.advance(by: .seconds(BlurtShared.hopReturnCap))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(bench.returns.hosts.isEmpty)

    // A window seen and then closed: the open did not hold.
    let later = await hopped(expectsKeeper: true)
    await later.rig.closed()
    #expect(later.coordinator.returnHost == nil)
    later.rig.clock.advance(by: .seconds(BlurtShared.hopReturnCap))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(later.returns.hosts.isEmpty)
  }
}
