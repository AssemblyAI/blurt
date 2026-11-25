import BlurtEngine
import Foundation
import Testing
import UIKit

@testable import BlurtiOSCore

@Suite("The two-process contract", .serialized)
@MainActor
struct ProtocolTests {
  @Test("the key-term key is the engine's own, so the app's and the keyboard's readers agree")
  func keyTermsKey() {
    #expect(SharedStore.keyTermsKey == KeyTermsStore.defaultsKey)
  }

  @Test("listening is the record's word: an open window with a live mic and a fresh lease")
  func isListening() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let now = Date()
    KeyboardRig.listening(true, now: now)
    #expect(SharedStore.isListening(now: now))
    // Closed or interrupted reads false however fresh the lease.
    KeyboardRig.record(.closed, reason: .sessionOff)
    #expect(!SharedStore.isListening(now: now))
    KeyboardRig.record(.interrupted, reason: .interrupted)
    #expect(!SharedStore.isListening(now: now))
    // Open with the mic not live, or with the lease lapsed, reads false too.
    KeyboardRig.record(.open, micLive: false)
    #expect(!SharedStore.isListening(now: now))
    KeyboardRig.record(.open, micLive: true, age: ListeningState.lease + 1)
    #expect(!SharedStore.isListening(now: now))
    // The record decides whenever there is one; the older keys answer for a
    // build that has not written it.
    SharedStore.listeningState = nil
    SharedStore.listeningUntil = now.addingTimeInterval(600)
    SharedStore.appSeenAt = now.addingTimeInterval(-2)
    #expect(SharedStore.isListening(now: now))
    SharedStore.appSeenAt = now.addingTimeInterval(-(SharedStore.presenceWindow + 1))
    #expect(!SharedStore.isListening(now: now))
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
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    #expect(SharedStore.addKeyTerm(" Rizz "))
    #expect(!SharedStore.addKeyTerm("rizz"))
    #expect(!SharedStore.addKeyTerm("  "))
    #expect(SharedStore.keyTerms == ["Rizz"])
  }

  /// A password field's words (#348/#349) are copied too — kept to this phone
  /// and expiring, options UIKit doesn't read back — never lost.
  @Test(
    "with no keyboard on screen the words go to the clipboard and the phase is the quiet one",
    arguments: [TargetSecurity.ordinary, .unknown, .secure])
  func relayFallsBackToClipboard(security: TargetSecurity) async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.keyboardSeenAt = nil
    UIPasteboard.general.string = ""
    let injector = KeyboardRelayInjector()
    await #expect(throws: BlurtError.noEditableTarget) {
      try await injector.insert("hello there", after: nil, windowTitle: nil, security: security)
    }
    #expect(UIPasteboard.general.string == "hello there")
    #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
  }

  @Test("a result the keyboard never takes is copied out after the delivery timeout")
  func relayTimesOut() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.keyboardSeenAt = Date()
    SharedStore.keyboardInstance = "kb-1"
    UIPasteboard.general.string = ""
    let clock = TestClock()
    let injector = KeyboardRelayInjector(clock: clock)
    let insert = Task { try await injector.insert("late words", after: nil, windowTitle: nil) }
    // Every poll but the last finds the result still waiting; only the step
    // onto the timeout copies it out.
    let polls = Int(.seconds(KeyboardRelayInjector.deliveryTimeout) / KeyboardRelayInjector.deliveryPoll)
    for _ in 0..<polls {
      await clock.waitUntilSleeping(for: KeyboardRelayInjector.deliveryPoll)
      #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result)?.text == "late words")
      #expect(UIPasteboard.general.string?.isEmpty == true)
      clock.advance(by: KeyboardRelayInjector.deliveryPoll)
    }
    await #expect(throws: BlurtError.noEditableTarget) { try await insert.value }
    #expect(UIPasteboard.general.string == "late words")
    #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
  }

  @Test("the words go back to the keyboard that pressed; another keyboard up in its place means the clipboard")
  func relayToPresser() async throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.keyboardSeenAt = Date()
    SharedStore.keyboardInstance = "kb-2"
    UIPasteboard.general.string = ""
    let elsewhere = KeyboardRelayInjector { ResultAddress(keyboard: "kb-1") }
    await #expect(throws: BlurtError.noEditableTarget) {
      try await elsewhere.insert("wrong app", after: nil, windowTitle: nil, security: .ordinary)
    }
    #expect(UIPasteboard.general.string == "wrong app")
    #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
    let clock = TestClock()
    let same = KeyboardRelayInjector(
      presser: { ResultAddress(keyboard: "kb-2", controllerID: "c-2") },
      clock: clock
    )
    let insert = Task { try await same.insert("right app", after: nil, windowTitle: nil) }
    let taken = await takeResult(stepping: clock)
    #expect(taken?.recipient == "kb-2" && taken?.controllerID == "c-2")
    try await insert.value
  }

  @Test("a dictation cancelled while its result waits for the keyboard takes the result back")
  func relayCancelledTakesResultBack() async throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.keyboardSeenAt = Date()
    SharedStore.keyboardInstance = "kb-1"
    let injector = KeyboardRelayInjector()
    let delivery = Task { try await injector.insert("never mind", after: nil, windowTitle: nil) }
    for _ in 0..<100 where SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result)?.text == "never mind")
    delivery.cancel()
    await #expect(throws: CancellationError.self) { try await delivery.value }
    #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
  }

  @Test("a result taken by the keyboard counts as delivered")
  func relayDelivered() async throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.keyboardSeenAt = Date()
    SharedStore.keyboardInstance = "kb-1"
    let clock = TestClock()
    let injector = KeyboardRelayInjector(clock: clock)
    let insert = Task { try await injector.insert("on time", after: nil, windowTitle: nil) }
    let taken = await takeResult(stepping: clock)
    try await insert.value
    #expect(taken?.text == "on time")
    #expect(taken?.recipient == "kb-1")
  }
}

/// Stands in for the keyboard: once the app has handed a result over, takes it
/// out of the store the way the keyboard's signal handler does, then steps the
/// relay's clock to its next poll so it sees the result gone.
private func takeResult(stepping clock: TestClock) async -> DictationResult? {
  let handed = await until { SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) != nil }
  guard handed else {
    return nil
  }
  let pending = SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result)
  SharedStore.remove(forKey: BlurtShared.Key.result)
  await clock.waitUntilSleeping(for: KeyboardRelayInjector.deliveryPoll)
  clock.advance(by: KeyboardRelayInjector.deliveryPoll)
  return pending
}
