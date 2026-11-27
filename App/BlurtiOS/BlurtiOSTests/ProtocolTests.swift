import BlurtEngine
import Foundation
import Testing
import UIKit

@testable import BlurtiOSCore

@Suite("The two-process contract", .serialized)
@MainActor
struct ProtocolTests {
  /// This test's own App Group: a fresh scratch suite each test, since
  /// Swift Testing runs every test on a new instance of the suite.
  let store = SharedStore.scratch()
  /// This test's own pasteboard for the relay's fallback: the general one is
  /// the simulator's, and every other test's copied words land there.
  let pasteboardName = "test-\(UUID().uuidString)"

  /// What the relay left on this test's pasteboard; nothing is "".
  var clipboard: String {
    UIPasteboard(name: .init(rawValue: pasteboardName), create: true)?.string ?? ""
  }

  @Test("the key-term key is the engine's own, so the app's and the keyboard's readers agree")
  func keyTermsKey() {
    #expect(SharedStore.keyTermsKey == KeyTermsStore.defaultsKey)
  }

  @Test("listening is the record's word: an open window with a live mic and a fresh lease")
  func isListening() {
    let now = Date()
    KeyboardRig.listening(true, in: store, now: now)
    #expect(store.isListening(now: now))
    // Closed or interrupted reads false however fresh the lease.
    KeyboardRig.record(.closed, in: store, reason: .sessionOff)
    #expect(!store.isListening(now: now))
    KeyboardRig.record(.interrupted, in: store, reason: .interrupted)
    #expect(!store.isListening(now: now))
    // Open with the mic not live, or with the lease lapsed, reads false too.
    KeyboardRig.record(.open, in: store, micLive: false)
    #expect(!store.isListening(now: now))
    KeyboardRig.record(.open, in: store, micLive: true, age: ListeningState.lease + 1)
    #expect(!store.isListening(now: now))
    // The record decides whenever there is one; the older keys answer for a
    // build that has not written it.
    store.listeningState = nil
    store.listeningUntil = now.addingTimeInterval(600)
    store.appSeenAt = now.addingTimeInterval(-2)
    #expect(store.isListening(now: now))
    store.appSeenAt = now.addingTimeInterval(-(SharedStore.presenceWindow + 1))
    #expect(!store.isListening(now: now))
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
    #expect(store.addKeyTerm(" Rizz "))
    #expect(!store.addKeyTerm("rizz"))
    #expect(!store.addKeyTerm("  "))
    #expect(store.keyTerms == ["Rizz"])
  }

  /// A password field's words (#348/#349) are copied too — kept to this phone
  /// and expiring, options UIKit doesn't read back — never lost.
  @Test(
    "with no keyboard on screen the words go to the clipboard and the phase is the quiet one",
    arguments: [TargetSecurity.ordinary, .unknown, .secure])
  func relayFallsBackToClipboard(security: TargetSecurity) async {
    store.keyboardSeenAt = nil
    let injector = KeyboardRelayInjector(store: store, pasteboardName: pasteboardName)
    await #expect(throws: BlurtError.noEditableTarget) {
      try await injector.insert("hello there", after: nil, windowTitle: nil, security: security)
    }
    #expect(clipboard == "hello there")
    #expect(store.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
  }

  @Test("a result the keyboard never takes is copied out after the delivery timeout")
  func relayTimesOut() async {
    store.keyboardSeenAt = Date()
    store.keyboardInstance = "kb-1"
    let clock = TestClock()
    let injector = KeyboardRelayInjector(store: store, clock: clock, pasteboardName: pasteboardName)
    let insert = Task { try await injector.insert("late words", after: nil, windowTitle: nil, security: .ordinary) }
    // Every poll but the last finds the result still waiting; only the step
    // onto the timeout copies it out.
    let polls = Int(.seconds(KeyboardRelayInjector.deliveryTimeout) / KeyboardRelayInjector.deliveryPoll)
    for _ in 0..<polls {
      #expect(await parked(on: clock, for: KeyboardRelayInjector.deliveryPoll))
      #expect(store.read(DictationResult.self, forKey: BlurtShared.Key.result)?.text == "late words")
      #expect(clipboard.isEmpty)
      clock.advance(by: KeyboardRelayInjector.deliveryPoll)
    }
    await #expect(throws: BlurtError.noEditableTarget) { try await insert.value }
    #expect(clipboard == "late words")
    #expect(store.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
  }

  @Test(
    "the words go back to the keyboard that pressed; another keyboard up in its place means the clipboard")
  func relayToPresser() async throws {
    store.keyboardSeenAt = Date()
    store.keyboardInstance = "kb-2"
    let elsewhere = KeyboardRelayInjector(
      store: store,
      presser: { ResultAddress(keyboard: "kb-1") },
      pasteboardName: pasteboardName
    )
    await #expect(throws: BlurtError.noEditableTarget) {
      try await elsewhere.insert("wrong app", after: nil, windowTitle: nil, security: .ordinary)
    }
    #expect(clipboard == "wrong app")
    #expect(store.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
    let clock = TestClock()
    let same = KeyboardRelayInjector(
      store: store,
      presser: { ResultAddress(keyboard: "kb-2", controllerID: "c-2") },
      clock: clock
    )
    let insert = Task { try await same.insert("right app", after: nil, windowTitle: nil, security: .ordinary) }
    let taken = await takeResult(from: store, stepping: clock)
    #expect(taken?.recipient == "kb-2" && taken?.controllerID == "c-2")
    try await insert.value
  }

  @Test("a dictation cancelled while its result waits for the keyboard takes the result back")
  func relayCancelledTakesResultBack() async throws {
    store.keyboardSeenAt = Date()
    store.keyboardInstance = "kb-1"
    let injector = KeyboardRelayInjector(store: store)
    let delivery = Task { try await injector.insert("never mind", after: nil, windowTitle: nil, security: .ordinary) }
    #expect(await until { store.read(DictationResult.self, forKey: BlurtShared.Key.result) != nil })
    #expect(store.read(DictationResult.self, forKey: BlurtShared.Key.result)?.text == "never mind")
    delivery.cancel()
    await #expect(throws: CancellationError.self) { try await delivery.value }
    #expect(store.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
  }

  @Test("a result taken by the keyboard counts as delivered")
  func relayDelivered() async throws {
    store.keyboardSeenAt = Date()
    store.keyboardInstance = "kb-1"
    let clock = TestClock()
    let injector = KeyboardRelayInjector(store: store, clock: clock)
    let insert = Task { try await injector.insert("on time", after: nil, windowTitle: nil, security: .ordinary) }
    let taken = await takeResult(from: store, stepping: clock)
    try await insert.value
    #expect(taken?.text == "on time")
    #expect(taken?.recipient == "kb-1")
  }
}

/// Stands in for the keyboard: once the app has handed a result over, takes it
/// out of `store` the way the keyboard's signal handler does, then steps the
/// relay's clock to its next poll so it sees the result gone.
private func takeResult(from store: SharedStore, stepping clock: TestClock) async -> DictationResult? {
  let handed = await until { store.read(DictationResult.self, forKey: BlurtShared.Key.result) != nil }
  guard handed else {
    return nil
  }
  let pending = store.read(DictationResult.self, forKey: BlurtShared.Key.result)
  store.remove(forKey: BlurtShared.Key.result)
  #expect(await parked(on: clock, for: KeyboardRelayInjector.deliveryPoll))
  clock.advance(by: KeyboardRelayInjector.deliveryPoll)
  return pending
}
