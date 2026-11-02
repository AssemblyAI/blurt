import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// The router around a read that's stopped, replaced or styled — with a speaker
/// that plays until stopped — and its real hold timer.
@MainActor
@Suite("SelectionSpeechRouter lifecycle")
struct SelectionSpeechRouterLifecycleTests {
  private let defaults = freshDefaults()

  /// A router over `speaker`, the selection read returning `selection()` each
  /// time, recording every callback it makes.
  private func router(
    _ speaker: GatedSpeaker, selection: @escaping @Sendable () -> String? = { "Hello there." }
  ) -> Rig {
    let fixture = makeSession()
    let router = SelectionSpeechRouter(
      session: fixture.session, speaker: speaker, readSelection: selection, defaults: defaults)
    let events = Events()
    router.speechStarted = { events.started += 1 }
    router.speechEnded = { events.ended += 1 }
    router.speechLevel = { events.levels.append($0) }
    router.speechFailed = { _ in events.failures += 1 }
    router.resetGate = { events.resets += 1 }
    return Rig(router: router, events: events, fixture: fixture)
  }

  /// A router under test, what it reported, and the session behind it.
  private struct Rig {
    let router: SelectionSpeechRouter
    let events: Events
    let fixture: SessionFixture
  }

  /// A tap of left ⌥ (reading aloud by default): press, then the gate's latch.
  private func tapRead(_ router: SelectionSpeechRouter) {
    router.press(key: .leftOption)
    router.keyLatched()
  }

  /// Starts a tapped read, waits for the speaker to be playing it, then stops it
  /// with a second press of the read key.
  private func readThenStop(_ router: SelectionSpeechRouter, _ speaker: GatedSpeaker) async throws {
    tapRead(router)
    try await waitUntil { speaker.calls.count == 1 }
    router.press(key: .leftOption)
  }

  // MARK: - E1: interrupted reads

  @Test("a stopped read ends once, at once, and its late unwinding changes nothing")
  func stopEndsOnce() async throws {
    let speaker = GatedSpeaker()
    let rig = router(speaker)
    let (router, events) = (rig.router, rig.events)
    try await readThenStop(router, speaker)
    #expect(events.ended == 1)
    #expect(!router.isSpeaking)
    try await waitUntil { speaker.cancellations == 1 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(events.ended == 1, "the cancelled task's end mustn't report again")
    #expect(events.failures == 0, "a stop is not a failure")
  }

  @Test("a stopped read's late end can't end the read that replaced it")
  func lateEndSparesTheNewerRead() async throws {
    let speaker = GatedSpeaker()
    let rig = router(speaker)
    let (router, events) = (rig.router, rig.events)
    try await readThenStop(router, speaker)
    tapRead(router)
    try await waitUntil { speaker.calls.count == 2 && speaker.cancellations == 1 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(events.started == 2)
    #expect(events.ended == 1)
    #expect(router.isSpeaking)
  }

  @Test("a level from a read that's over never reaches the pill")
  func lateLevelsAreDropped() async throws {
    let speaker = GatedSpeaker()
    let rig = router(speaker)
    let (router, events) = (rig.router, rig.events)
    try await readThenStop(router, speaker)
    let atEnd = events.levels
    try await waitUntil { speaker.cancellations == 1 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(atEnd.last == 0, "the end zeroes the meter")
    #expect(events.levels == atEnd, "the stopped speaker's late level was dropped")
  }

  @Test("the dictation key stopping a read leaves the gate of the dictation it starts alone")
  func stopKeepsTheNewDictationsGate() async throws {
    let speaker = GatedSpeaker()
    let rig = router(speaker)
    let (router, events) = (rig.router, rig.events)
    tapRead(router)
    try await waitUntil { speaker.calls.count == 1 }
    let resets = events.resets
    router.press(key: .rightCommand)
    try await waitUntil { speaker.cancellations == 1 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(events.resets == resets, "the stopped read must not reset the dictation's gate")
    #expect(events.ended == 1)
  }

  // MARK: - E4: styles and samples

  @Test("each press reads with the style set at that moment")
  func styleChangesReachTheNextRead() async throws {
    let speaker = GatedSpeaker()
    let rig = router(speaker)
    let router = rig.router
    tapRead(router)
    try await waitUntil { speaker.calls.count == 1 }
    speaker.finishAll()
    try await waitUntil { !router.isSpeaking }
    defaults.set(2.0, forKey: ReadAloudStyleStore.speedDefaultsKey)
    defaults.set("aai-buford", forKey: ReadAloudStyleStore.voiceDefaultsKey)
    tapRead(router)
    try await waitUntil { speaker.calls.count == 2 }
    #expect(speaker.calls[0].style.rate == 1)
    #expect(speaker.calls[1].style == ReadAloudStyle(rate: 2, skipsJargon: true, voiceID: "aai-buford"))
  }

  @Test("an answer reads with the style set when it's asked")
  func styleReachesTheAnswer() async throws {
    let speaker = GatedSpeaker()
    let rig = router(speaker)
    let (router, fixture) = (rig.router, rig.fixture)
    TriggerKeyStyleStore(defaults: defaults).setChoice(.ask, for: .leftControl)
    defaults.set(1.5, forKey: ReadAloudStyleStore.speedDefaultsKey)
    let phases = Task {
      for await phase in await fixture.session.phaseStream() { router.sessionPhaseChanged(phase) }
    }
    defer { phases.cancel() }
    router.press(key: .leftControl)
    let deadline = ContinuousClock.now + .seconds(5)
    while await fixture.mic.startCalls == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    router.submit(.release)
    try await waitUntil { speaker.calls.count == 1 }
    #expect(speaker.calls[0].kind == "answer: Hello world.")
    #expect(speaker.calls[0].style.rate == 1.5)
    // The answer's start (pill and chime) waits a beat after the ask's end, so
    // the two chimes don't run together; then it comes.
    #expect(rig.events.started == 0)
    try await waitUntil { rig.events.started == 1 }
  }

  @Test("a newer sample cuts off the older one without a failure, and a sample shows no pill")
  func samples() async throws {
    let speaker = GatedSpeaker()
    let rig = router(speaker)
    let (router, events) = (rig.router, rig.events)
    router.previewSample()
    try await waitUntil { speaker.calls.count == 1 }
    router.previewSample()
    try await waitUntil { speaker.calls.count == 2 && speaker.cancellations == 1 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(events.failures == 0)
    #expect(events.started == 0 && events.ended == 0)
  }

  @Test("a failed sample is reported")
  func failedSample() async throws {
    let speaker = GatedSpeaker(fails: true)
    let rig = router(speaker)
    let (router, events) = (rig.router, rig.events)
    router.previewSample()
    try await waitUntil { events.failures == 1 }
  }

  // MARK: - E5: the real hold timer

  @Test("a held read starts once the key has been down for the hold delay")
  func heldReadStartsAfterTheDelay() async throws {
    let speaker = GatedSpeaker()
    let rig = router(speaker)
    let (router, events) = (rig.router, rig.events)
    let pressed = ContinuousClock.now
    router.press(key: .leftOption)
    try await waitUntil { events.started == 1 }
    #expect(ContinuousClock.now - pressed >= .milliseconds(300))
  }

  @Test("a press's leftover timer can't mark the next press as a hold early")
  func leftoverTimerIsCancelled() async throws {
    let speaker = GatedSpeaker()
    let reads = Counter()
    // The first press finds nothing selected; the second finds text.
    let rig = router(speaker, selection: { reads.next() == 1 ? nil : "Hello there." })
    let (router, events) = (rig.router, rig.events)
    router.press(key: .leftOption)
    try await Task.sleep(for: .milliseconds(200))
    let second = ContinuousClock.now
    router.press(key: .leftOption)
    try await waitUntil { events.started == 1 }
    #expect(ContinuousClock.now - second >= .milliseconds(300), "the first press's timer fired for the second")
  }
}

/// What the router reported, in order.
@MainActor
private final class Events {
  var started = 0
  var ended = 0
  var levels: [Float] = []
  var failures = 0
  var resets = 0
}

/// A speaker that records each call and "plays" until stopped or released. A
/// stopped one reports one more meter level as it unwinds — a tick already on
/// its way — before throwing.
final class GatedSpeaker: ReadAloudSpeaker, Sendable {
  struct Call: Sendable {
    let kind: String
    let style: ReadAloudStyle
  }

  private struct State {
    var calls: [Call] = []
    var cancellations = 0
    var released = false
  }

  private let state = Mutex(State())
  private let fails: Bool

  init(fails: Bool = false) { self.fails = fails }

  var calls: [Call] { state.withLock(\.calls) }
  var cancellations: Int { state.withLock(\.cancellations) }

  /// Lets every read playing now, and any later, finish on its own.
  func finishAll() { state.withLock { $0.released = true } }

  func speak(_ text: String, style: ReadAloudStyle, onLevel: (@Sendable (Float) -> Void)?) async throws {
    try await play(Call(kind: "speak: \(text)", style: style), onLevel: onLevel)
  }

  func answer(
    _ request: String, about selection: String, style: ReadAloudStyle, onLevel: (@Sendable (Float) -> Void)?
  ) async throws {
    try await play(Call(kind: "answer: \(request)", style: style), onLevel: onLevel)
  }

  private func play(_ call: Call, onLevel: (@Sendable (Float) -> Void)?) async throws {
    state.withLock { $0.calls.append(call) }
    if fails { throw URLError(.badServerResponse) }
    while !state.withLock(\.released) {
      do {
        try await Task.sleep(for: .milliseconds(5))
      } catch {
        state.withLock { $0.cancellations += 1 }
        onLevel?(0.7)
        throw error
      }
    }
  }
}
