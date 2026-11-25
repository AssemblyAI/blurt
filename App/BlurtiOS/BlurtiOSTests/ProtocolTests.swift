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
    arguments: [false, true])
  func relayFallsBackToClipboard(secure: Bool) async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.keyboardSeenAt = nil
    UIPasteboard.general.string = ""
    let injector = KeyboardRelayInjector()
    await #expect(throws: BlurtError.noEditableTarget) {
      try await injector.insert("hello there", after: nil, windowTitle: nil, secure: secure)
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
    let injector = KeyboardRelayInjector()
    let started = Date()
    await #expect(throws: BlurtError.noEditableTarget) {
      try await injector.insert("late words", after: nil, windowTitle: nil, secure: false)
    }
    #expect(Date().timeIntervalSince(started) >= KeyboardRelayInjector.deliveryTimeout - 0.5)
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
      try await elsewhere.insert("wrong app", after: nil, windowTitle: nil, secure: false)
    }
    #expect(UIPasteboard.general.string == "wrong app")
    #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
    let same = KeyboardRelayInjector { ResultAddress(keyboard: "kb-2", controllerID: "c-2") }
    let taker = takeResultShortly()
    try await same.insert("right app", after: nil, windowTitle: nil, secure: false)
    let taken = await taker.value
    #expect(taken?.recipient == "kb-2" && taken?.controllerID == "c-2")
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
    let injector = KeyboardRelayInjector()
    let taker = takeResultShortly()
    try await injector.insert("on time", after: nil, windowTitle: nil, secure: false)
    let taken = await taker.value
    #expect(taken?.text == "on time")
    #expect(taken?.recipient == "kb-1")
  }
}

/// Stands in for the keyboard: a moment after the app hands a result over, takes
/// it out of the store the way the keyboard's signal handler does.
private func takeResultShortly() -> Task<DictationResult?, Never> {
  Task {
    try? await Task.sleep(for: .milliseconds(300))
    let pending = SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result)
    SharedStore.remove(forKey: BlurtShared.Key.result)
    return pending
  }
}
