import Foundation
import Testing

@testable import BlurtiOSCore

// MARK: - The records beside the transitions
//
// Where the closing record sits among a close's effects, the record the
// machine gives for the state as it stands, and the beat with no window.

extension ListeningWindowMachineTests {
  @Test("a close publishes its record first, before the dictation ends and the source closes")
  func closePublishesFirst() {
    var dictating = openWindow(dictating: true)
    let stop = dictating.handle(.closeRequested, now: t0 + 1)
    #expect(stop.count == 4)
    #expect(records(stop).first?.window == .closing)
    #expect(stop.dropFirst().elementsEqual([.endUtterance(keepWords: false), .closeSource(1), standDown]))
    var open = openWindow()
    let expired = open.handle(.expired(1), now: t0 + window)
    #expect(records(expired).first?.window == .closing && expired.count == 3)
    #expect(expired.dropFirst().elementsEqual([.closeSource(1), standDown]))
    var interrupted = interruptedWindow()
    let turnedOff = interrupted.handle(.foregrounded(turnedOff: true), now: t0 + 1)
    #expect(records(turnedOff).first?.window == .closing)
    #expect(turnedOff.dropFirst().elementsEqual([.closeSource(1), leaveActive, .log(Machine.stopWhileInterruptedLog)]))
    var reset = openWindow(dictating: true)
    let mediaReset = reset.handle(.mediaReset(1), now: t0 + 1)
    #expect(records(mediaReset).first?.reason == .mediaReset)
    #expect(mediaReset.dropFirst().elementsEqual([.endUtterance(keepWords: true), .closeSource(1), standDown]))
    #expect(records(reset.handle(.closed(1), now: t0 + 2)).count == 1, "closed publishes once more")
  }

  @Test("current reads the state as it stands, the sequence unmoved, the mic as the last beat read it")
  func currentRecord() throws {
    var m = openWindow()
    let open = m.current(now: t0 + 1)
    #expect(open.window == .open && open.micLive && open.reason == nil && open.sequence == m.sequence)
    #expect(open.windowUntil == t0 + window && open.writtenAt == t0 + 1 && open.launchID == launch)
    _ = m.heartbeat(micLive: false, now: t0 + 2)
    #expect(!m.current(now: t0 + 3).micLive && m.current(now: t0 + 3).notReady(now: t0 + 3) == .micBusy)
    _ = m.heartbeat(micLive: true, now: t0 + 4)
    _ = m.handle(.interruptionBegan(1, .interrupted), now: t0 + 5)
    #expect(!m.current(now: t0 + 6).micLive && m.current(now: t0 + 6).window == .interrupted)
    _ = m.handle(.resumed(1), now: t0 + 7)
    let sequence = m.sequence
    _ = m.handle(.closeRequested, now: t0 + 8)
    let closing = m.current(now: t0 + 9)
    #expect(closing.window == .closing && !closing.micLive && closing.reason == .sessionOff)
    #expect(closing.sequence == sequence + 1 && closing.sequence == m.sequence)
    let fresh = fresh().current(now: t0)
    #expect(fresh.window == .closed && fresh.reason == .sessionOff && fresh.sequence == 0 && !fresh.micLive)
    #expect(try record(m.handle(.closed(1), now: t0 + 10)).sequence == closing.sequence + 1)
  }

  @Test("a beat with no window renews the record given: the lease on, the reason kept, the sequence the machine's")
  func heartbeatRenewing() throws {
    var m = fresh()
    let launched = ListeningState.launched(launch, at: t0)
    let beatAt: Date = t0 + 5
    let beat = try record(m.heartbeat(renewing: launched, now: beatAt))
    #expect(beat.window == .closed && beat.reason == .sessionOff && !beat.micLive && beat.launchID == launch)
    #expect(beat.sequence == 1 && beat.writtenAt == beatAt && beat.leaseUntil == beatAt + ListeningState.lease)
    let again = try record(m.heartbeat(renewing: beat, now: t0 + 10))
    #expect(again.sequence == 2 && again.leaseUntil == t0 + 10 + ListeningState.lease)
    let opening = try record(m.handle(.openRequested(inForeground: true), now: t0 + 11))
    #expect(opening.sequence == 3, "the window's first record follows the beats")
    var refused = fresh()
    let refusal = try record(refused.handle(.openRequested(inForeground: false), now: t0))
    let kept = try record(refused.heartbeat(renewing: refusal, now: t0 + 5))
    #expect(kept.reason == .needsForeground && kept.window == .closed && kept.sequence == refusal.sequence + 1)
    #expect(kept.notReady(now: t0 + 5) == .needsForeground)
  }
}
