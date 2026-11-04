import BlurtEngine
import Foundation
import Testing

@testable import BlurtiOSCore

/// The listening window's transition table, a row at a time, and what every row's record promises the keyboard.
@Suite("Listening window machine")
struct ListeningWindowMachineTests {
  private typealias Machine = ListeningWindowMachine
  private typealias Effect = Machine.Effect

  private let launch = UUID()
  private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
  /// The setting's default, shorter than the longest dictation so the floor shows.
  private let minutes = 15
  private let maxAudio = SyncSTTLimits.maxAudioSeconds
  private let held = Machine.State.open(1, idle: .held, utterance: false)
  private let paused = Machine.State.interrupted(1, reason: .interrupted, resumable: true)
  private let standDown = Effect.deactivateSession(skipIfInterrupted: false)
  private let leaveActive = Effect.deactivateSession(skipIfInterrupted: true)

  @Test("closed + openRequested in front → opening: the session up, the source opening")
  func openFromClosed() throws {
    var m = fresh()
    let asks: [Effect] = [.activateSession, .openSource(1)]
    let record = try row(&m, .openRequested(inForeground: true), at: t0, lands: .opening(1), asks: asks)
    #expect(record.window == .opening && !record.micLive && record.reason == .opening)
    #expect(record.launchID == launch && record.sequence == 1 && record.windowUntil == nil)
  }

  @Test("the foreground gate: an open asked for from the background is refused, never a source start")
  func openNeedsForeground() throws {
    var m = fresh()
    let log = Effect.log("open refused: the app is not in front")
    let record = try row(&m, .openRequested(inForeground: false), at: t0, lands: .closed, asks: [log])
    #expect(record.window == .closed && record.reason == .needsForeground)
    #expect(record.notReady(now: t0) == .needsForeground)
  }

  @Test("opening + opened → open: the expiry a window out, the record ready")
  func openedRow() throws {
    var m = openWindow(opened: false)
    let record = try row(&m, .opened(1), at: t0, lands: held, asks: [.scheduleExpiry(t0 + window, 1)])
    #expect(record.window == .open && record.micLive && record.reason == nil)
    #expect(record.windowUntil == t0 + window && record.isReady(now: t0))
  }

  @Test("opening + openFailed → closed with the reason, the source and session stood down")
  func openFailed() throws {
    var m = openWindow(opened: false)
    let asks: [Effect] = [.closeSource(1), standDown]
    let record = try row(&m, .openFailed(1, .micDenied), at: t0, lands: .closed, asks: asks)
    #expect(record.window == .closed && record.reason == .micDenied)
  }

  @Test("open + openRequested → a refresh: the expiry pushed out and republished, never a second source")
  func openWhileOpen() throws {
    var m = openWindow()
    let expiry = Effect.scheduleExpiry(t0 + 100 + window, 1)
    let record = try row(&m, .openRequested(inForeground: true), at: t0 + 100, lands: held, asks: [expiry])
    #expect(record.windowUntil == t0 + 100 + window && record.micLive)
    var dictating = openWindow(dictating: true)
    let refreshed = dictating.handle(.openRequested(inForeground: true), now: t0 + 100)
    #expect(actions(refreshed) == [.scheduleExpiry(t0 + 100 + maxAudio, 1)], "a refresh keeps the dictation's floor")
  }

  @Test("a dictation's start floors the expiry at the longest a dictation can run")
  func utteranceStartFloorsExpiry() throws {
    var m = openWindow()
    #expect(window < maxAudio)
    let dictating = Machine.State.open(1, idle: .held, utterance: true)
    let expiry = Effect.scheduleExpiry(t0 + 10 + maxAudio, 1)
    let record = try row(&m, .utteranceStarted(1), at: t0 + 10, lands: dictating, asks: [expiry])
    #expect(record.utterance && record.micLive && record.windowUntil == t0 + 10 + maxAudio)
    var long = openWindow(minutes: 30)
    #expect(actions(long.handle(.utteranceStarted(1), now: t0)) == [.scheduleExpiry(t0 + 30 * 60, 1)])
  }

  @Test("the lifetime counts from the last word: utteranceEnded reschedules a window out from then")
  func lifetimeFromUtteranceEnd() throws {
    var m = openWindow(dictating: true)
    let expiry = Effect.scheduleExpiry(t0 + 500 + window, 1)
    let record = try row(&m, .utteranceEnded(1), at: t0 + 500, lands: held, asks: [expiry])
    #expect(!record.utterance && record.windowUntil == t0 + 500 + window)
  }

  @Test("windowMinutes 0 is until stopped: no end and no expiry, ever")
  func untilStopped() throws {
    var m = openWindow(minutes: Machine.untilStopped, opened: false)
    let record = try row(&m, .opened(1), at: t0, lands: held, asks: [])
    #expect(record.windowUntil == nil && record.isReady(now: t0))
    #expect(actions(m.handle(.utteranceStarted(1), now: t0)).isEmpty)
    #expect(actions(m.handle(.utteranceEnded(1), now: t0 + 5)).isEmpty)
    #expect(actions(m.handle(.openRequested(inForeground: true), now: t0 + 9)).isEmpty)
    #expect(m.windowUntil == nil)
  }

  @Test("open + interruptionBegan → interrupted: the window kept, a background task held, the mic not live")
  func interruptionBegan() throws {
    var m = openWindow()
    let event = Machine.Event.interruptionBegan(1, .interrupted)
    let record = try row(&m, event, at: t0 + 1, lands: paused, asks: [.beginBackgroundTask])
    #expect(record.window == .interrupted && !record.micLive && record.reason == .interrupted)
    #expect(record.windowUntil == t0 + window && record.notReady(now: t0 + 1) == .interrupted)
    var dictating = openWindow(dictating: true)
    let asks: [Effect] = [.endUtterance(keepWords: true), .beginBackgroundTask]
    #expect(actions(dictating.handle(event, now: t0 + 1)) == asks, "mid-dictation, the words are released first")
  }

  @Test("open + sourceDied → interrupted with the source's reason, no background task")
  func sourceDied() throws {
    var m = openWindow(dictating: true)
    let died = Machine.State.interrupted(1, reason: .micBusy, resumable: true)
    let asks: [Effect] = [.endUtterance(keepWords: true)]
    let record = try row(&m, .sourceDied(1, .micBusy), at: t0 + 1, lands: died, asks: asks)
    #expect(!record.micLive && record.reason == .micBusy)
  }

  @Test("interruptionEnded with shouldResume → a poll, never a start from the background")
  func interruptionEnded() {
    var m = interruptedWindow()
    #expect(m.handle(.interruptionEnded(1, shouldResume: true), now: t0 + 2) == [.tryResume(1, mayStart: false)])
    #expect(m.state == paused)
  }

  @Test("foregrounded while interrupted → a resume that may start the source")
  func foregroundedResumes() {
    var m = interruptedWindow()
    #expect(m.handle(.foregrounded(turnedOff: false), now: t0 + 2) == [.tryResume(1, mayStart: true)])
    #expect(m.state == paused)
  }

  @Test("foregrounded with the session turned off → closing(stop): the off switch wins")
  func foregroundedTurnedOff() throws {
    var m = interruptedWindow()
    let asks: [Effect] = [.closeSource(1), leaveActive]
    let record = try row(&m, .foregrounded(turnedOff: true), at: t0 + 2, lands: .closing(1, cause: .stop), asks: asks)
    #expect(record.window == .closing && !record.micLive)
  }

  @Test("resumed → open again: the background task ended, the expiry back where it was")
  func resumed() throws {
    var m = interruptedWindow()
    let asks: [Effect] = [.endBackgroundTask, .scheduleExpiry(t0 + window, 1)]
    let record = try row(&m, .resumed(1), at: t0 + 3, lands: held, asks: asks)
    #expect(record.window == .open && record.micLive && record.isReady(now: t0 + 3))
  }

  @Test("resumeFailed stays interrupted with the new reason, not resumable, never closed")
  func resumeFailed() throws {
    var m = interruptedWindow()
    let stuck = Machine.State.interrupted(1, reason: .needsForeground, resumable: false)
    let record = try row(&m, .resumeFailed(1, .needsForeground), at: t0 + 3, lands: stuck, asks: [.endBackgroundTask])
    #expect(record.window == .interrupted && record.reason == .needsForeground)
    #expect(m.handle(.interruptionEnded(1, shouldResume: true), now: t0 + 4).isEmpty)
    #expect(m.handle(.foregrounded(turnedOff: false), now: t0 + 5) == [.tryResume(1, mayStart: true)])
  }

  @Test("a hop while interrupted reopens under a new generation; the old one's events are stale")
  func reopenWhileInterrupted() throws {
    var m = interruptedWindow()
    let asks: [Effect] = [.closeSource(1), .endBackgroundTask, .activateSession, .openSource(2)]
    let record = try row(&m, .openRequested(inForeground: true), at: t0 + 3, lands: .opening(2), asks: asks)
    #expect(record.window == .opening && record.windowUntil == nil)
    #expect(m.handle(.closed(1), now: t0 + 4) == [.log("\(Machine.staleGenerationLog) 1 (current 2)")])
    #expect(m.state == .opening(2))
  }

  @Test("closeRequested cancels: the dictation dropped, the source closed, the session down")
  func closeRequested() throws {
    var m = openWindow(dictating: true)
    let asks: [Effect] = [.endUtterance(keepWords: false), .closeSource(1), standDown]
    let record = try row(&m, .closeRequested, at: t0 + 1, lands: .closing(1, cause: .stop), asks: asks)
    #expect(record.window == .closing && !record.micLive && record.windowUntil == nil)
    #expect(record.reason == .sessionOff)
  }

  @Test("closeRequested while opening → closing(stop), nothing to end")
  func closeWhileOpening() throws {
    var m = openWindow(opened: false)
    try row(&m, .closeRequested, at: t0 + 1, lands: .closing(1, cause: .stop), asks: [.closeSource(1), standDown])
  }

  @Test("closeRequested while interrupted leaves the session active and says so")
  func closeWhileInterrupted() {
    var m = interruptedWindow()
    let effects = actions(m.handle(.closeRequested, now: t0 + 1))
    #expect(m.state == .closing(1, cause: .stop))
    #expect(effects.first == .closeSource(1) && effects.contains(leaveActive))
    #expect(effects.contains { if case .log = $0 { true } else { false } })
    #expect(!effects.contains(.endUtterance(keepWords: false)))
  }

  @Test("expired → closing(expiry); closed → closed, the record saying the session is off")
  func expiry() throws {
    var m = openWindow()
    let ending = Machine.State.closing(1, cause: .expiry)
    try row(&m, .expired(1), at: t0 + window, lands: ending, asks: [.closeSource(1), standDown])
    let asks: [Effect] = [.endBackgroundTask, .cancelExpiry]
    let record = try row(&m, .closed(1), at: t0 + window + 1, lands: .closed, asks: asks)
    #expect(record.window == .closed && record.reason == .sessionOff && record.windowUntil == nil)
    var dictating = openWindow(dictating: true)
    #expect(actions(dictating.handle(.expired(1), now: t0 + maxAudio)).first == .endUtterance(keepWords: true))
  }

  @Test("expiry while interrupted closes, the session left active")
  func expiryWhileInterrupted() throws {
    var m = interruptedWindow()
    let ending = Machine.State.closing(1, cause: .expiry)
    try row(&m, .expired(1), at: t0 + window, lands: ending, asks: [.closeSource(1), leaveActive])
  }

  @Test("mediaReset closes, open or interrupted, and the closed record names it")
  func mediaReset() throws {
    var open = openWindow()
    let reset = Machine.State.closing(1, cause: .mediaReset)
    try row(&open, .mediaReset(1), at: t0 + 1, lands: reset, asks: [.closeSource(1), standDown])
    let asks: [Effect] = [.endBackgroundTask, .cancelExpiry]
    let record = try row(&open, .closed(1), at: t0 + 2, lands: .closed, asks: asks)
    #expect(record.reason == .mediaReset)
    var interrupted = interruptedWindow()
    try row(&interrupted, .mediaReset(1), at: t0 + 1, lands: reset, asks: [.closeSource(1), leaveActive])
  }

  @Test("events with nothing to do change nothing: a second open, a foreground, a stop with no window")
  func nothingToDo() {
    var starting = openWindow(opened: false)
    #expect(starting.handle(.openRequested(inForeground: true), now: t0 + 1).isEmpty && starting.state == .opening(1))
    var open = openWindow()
    #expect(open.handle(.utteranceEnded(1), now: t0).isEmpty)
    #expect(open.handle(.foregrounded(turnedOff: true), now: t0).isEmpty)
    _ = open.handle(.utteranceStarted(1), now: t0)
    #expect(open.handle(.utteranceStarted(1), now: t0).isEmpty && open.state == .open(1, idle: .held, utterance: true))
    var waiting = interruptedWindow()
    #expect(waiting.handle(.interruptionEnded(1, shouldResume: false), now: t0).isEmpty)
    #expect(waiting.handle(.openRequested(inForeground: false), now: t0).isEmpty && waiting.state == paused)
    var closing = openWindow()
    _ = closing.handle(.closeRequested, now: t0)
    #expect(closing.handle(.closeRequested, now: t0).isEmpty && closing.handle(.expired(1), now: t0).isEmpty)
    #expect(closing.handle(.openRequested(inForeground: true), now: t0).isEmpty)
    #expect(closing.handle(.foregrounded(turnedOff: false), now: t0).isEmpty)
    #expect(closing.state == .closing(1, cause: .stop))
    var closed = fresh()
    #expect(closed.handle(.closeRequested, now: t0).isEmpty)
    #expect(closed.handle(.foregrounded(turnedOff: true), now: t0).isEmpty && closed.state == .closed)
  }
}

// MARK: - Generations and the record

extension ListeningWindowMachineTests {
  @Test("an event from another generation is logged and changes nothing")
  func staleGeneration() {
    var m = openWindow()
    #expect(m.handle(.utteranceStarted(7), now: t0) == [.log("\(Machine.staleGenerationLog) 7 (current 1)")])
    #expect(m.state == held)
    var closed = fresh()
    #expect(closed.handle(.opened(1), now: t0) == [.log("\(Machine.staleGenerationLog) 1 (current none)")])
    #expect(closed.state == .closed)
  }

  @Test("generations climb across windows, and states and events name theirs")
  func generationsClimb() {
    var m = openWindow()
    _ = m.handle(.closeRequested, now: t0)
    _ = m.handle(.closed(1), now: t0)
    _ = m.handle(.openRequested(inForeground: true), now: t0)
    #expect(m.state == .opening(2) && m.state.generation == 2 && Machine.State.closed.generation == nil)
    #expect(Machine.Event.closeRequested.generation == nil && Machine.Event.expired(3).generation == 3)
  }

  @Test("idleChanged republishes with the new idle, the mic still live, and it survives an interruption")
  func idleChanged() throws {
    var m = openWindow()
    let pip = Machine.State.open(1, idle: .pip, utterance: false)
    let record = try row(&m, .idleChanged(1, .pip), at: t0 + 1, lands: pip, asks: [])
    #expect(record.idle == .pip && record.micLive)
    _ = m.handle(.interruptionBegan(1, .interrupted), now: t0 + 2)
    _ = m.handle(.idleChanged(1, .held), now: t0 + 3)
    _ = m.handle(.resumed(1), now: t0 + 4)
    #expect(m.state == held)
  }

  @Test("heartbeat renews the lease and takes micLive from the source, but only while open")
  func heartbeat() throws {
    var m = openWindow()
    let beat = try record(m.heartbeat(micLive: true, now: t0 + 5))
    #expect(beat.writtenAt == t0 + 5 && beat.leaseUntil == t0 + 5 + ListeningState.lease)
    #expect(beat.window == .open && beat.micLive && beat.sequence == 3)
    let quiet = try record(m.heartbeat(micLive: false, now: t0 + 10))
    #expect(!quiet.micLive && quiet.sequence == 4 && m.state == held)
    _ = m.handle(.interruptionBegan(1, .interrupted), now: t0 + 11)
    let interrupted = try record(m.heartbeat(micLive: true, now: t0 + 15))
    #expect(!interrupted.micLive && interrupted.window == .interrupted)
    var closed = fresh()
    let off = try record(closed.heartbeat(micLive: true, now: t0))
    #expect(off.window == .closed && !off.micLive && off.leaseUntil == t0 + ListeningState.lease)
  }

  @Test("every publish's sequence strictly increases")
  func sequenceClimbs() {
    let sequences = wholeLife().map(\.sequence)
    #expect(sequences.count > 20)
    #expect(zip(sequences, sequences.dropFirst()).allSatisfy { $0 < $1 })
  }

  @Test("the lease is never distantFuture: always writtenAt plus the contract's lease")
  func leaseIsReal() {
    for record in wholeLife() {
      #expect(record.leaseUntil != .distantFuture && record.leaseUntil == record.writtenAt + ListeningState.lease)
      #expect(record.launchID == launch && record.version == ListeningState.contractVersion)
    }
  }

  @Test("micLive, and so readiness, only ever say yes while the window is open")
  func micLiveOnlyOpen() {
    for record in wholeLife() {
      #expect(record.micLive == (record.window == .open))
      #expect(record.isReady(now: record.writtenAt) == (record.window == .open))
    }
  }
}

// MARK: - The rig

extension ListeningWindowMachineTests {
  private var window: TimeInterval { TimeInterval(minutes * 60) }

  private func fresh(minutes: Int? = nil) -> Machine {
    Machine(launchID: launch, windowMinutes: minutes ?? self.minutes, maxAudioSeconds: maxAudio)
  }

  /// A window opened at `t0` (generation 1) with nothing — or a dictation — in flight; `opened: false` leaves it opening.
  private func openWindow(minutes: Int? = nil, opened: Bool = true, dictating: Bool = false) -> Machine {
    var machine = fresh(minutes: minutes)
    _ = machine.handle(.openRequested(inForeground: true), now: t0)
    if opened { _ = machine.handle(.opened(1), now: t0) }
    if dictating { _ = machine.handle(.utteranceStarted(1), now: t0) }
    return machine
  }

  /// An open window a call took the microphone from, at `t0`.
  private func interruptedWindow() -> Machine {
    var machine = openWindow()
    _ = machine.handle(.interruptionBegan(1, .interrupted), now: t0)
    return machine
  }

  /// The effects apart from the record they publish.
  private func actions(_ effects: [Effect]) -> [Effect] {
    effects.filter { if case .publish = $0 { false } else { true } }
  }

  private func records(_ effects: [Effect]) -> [ListeningState] {
    effects.compactMap { if case .publish(let record) = $0 { record } else { nil } }
  }

  /// The one record a transition publishes.
  private func record(_ effects: [Effect], at location: SourceLocation = #_sourceLocation) throws -> ListeningState {
    let published = records(effects)
    #expect(published.count == 1, sourceLocation: location)
    return try #require(published.first, sourceLocation: location)
  }

  /// One row: where the event lands the machine and what it asks for, answering the record it publishes.
  @discardableResult
  private func row(
    _ machine: inout Machine, _ event: Machine.Event, at now: Date, lands state: Machine.State,
    asks expected: [Effect], location: SourceLocation = #_sourceLocation
  ) throws -> ListeningState {
    let effects = machine.handle(event, now: now)
    #expect(machine.state == state, sourceLocation: location)
    #expect(actions(effects) == expected, sourceLocation: location)
    return try record(effects, at: location)
  }

  /// Every row and a beat after each, in one life: refused, opened, dictated, interrupted, resumed, stopped.
  private func wholeLife() -> [ListeningState] {
    var m = fresh()
    var records: [ListeningState] = []
    let steps: [(Machine.Event, TimeInterval)] = [
      (.openRequested(inForeground: false), 0), (.openRequested(inForeground: true), 1), (.opened(1), 2),
      (.utteranceStarted(1), 3), (.utteranceEnded(1), 20), (.interruptionBegan(1, .interrupted), 30),
      (.interruptionEnded(1, shouldResume: true), 40), (.resumeFailed(1, .needsForeground), 41),
      (.foregrounded(turnedOff: false), 50), (.resumed(1), 51), (.idleChanged(1, .pip), 52),
      (.openRequested(inForeground: true), 60), (.closeRequested, 70), (.closed(1), 71),
    ]
    for (event, offset) in steps {
      records += self.records(m.handle(event, now: t0 + offset))
      records += self.records(m.heartbeat(micLive: true, now: t0 + offset))
    }
    return records
  }
}
