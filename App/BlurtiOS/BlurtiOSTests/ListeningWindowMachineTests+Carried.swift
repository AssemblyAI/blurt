import Foundation
import Testing

@testable import BlurtiOSCore

// MARK: - What the machine carries across transitions
//
// The reason a window closed for, a hop that landed while it was closing, a
// source lost while it was still opening, the last heartbeat's micLive, and
// the window length as Settings last set it.

extension ListeningWindowMachineTests {
  @Test("a closed record keeps its reason across heartbeats: the failed open's, the refusal's, the cause's")
  func closedReasonSurvivesHeartbeats() throws {
    var failed = openWindow(opened: false)
    _ = failed.handle(.openFailed(1, .micDenied), now: t0)
    let denied = try record(failed.heartbeat(micLive: true, now: t0 + 5))
    #expect(denied.window == .closed && !denied.micLive && denied.reason == .micDenied)
    var refused = fresh()
    _ = refused.handle(.openRequested(inForeground: false), now: t0)
    #expect(try record(refused.heartbeat(micLive: false, now: t0 + 5)).reason == .needsForeground)
    var reset = openWindow()
    _ = reset.handle(.mediaReset(1), now: t0 + 1)
    _ = reset.handle(.closed(1), now: t0 + 2)
    #expect(try record(reset.heartbeat(micLive: false, now: t0 + 7)).reason == .mediaReset)
    #expect(try record(reset.heartbeat(micLive: false, now: t0 + 12)).reason == .mediaReset)
  }

  @Test("the closed record after a Stop carries .sessionOff, and the next window forgets the last reason")
  func stopClosesWithSessionOff() throws {
    var m = openWindow(opened: false)
    _ = m.handle(.openFailed(1, .micDenied), now: t0)
    _ = m.handle(.openRequested(inForeground: true), now: t0 + 1)
    _ = m.handle(.opened(2), now: t0 + 2)
    _ = m.handle(.closeRequested, now: t0 + 3)
    let closed = try record(m.handle(.closed(2), now: t0 + 4))
    #expect(closed.window == .closed && closed.reason == .sessionOff)
    #expect(try record(m.heartbeat(micLive: true, now: t0 + 9)).reason == .sessionOff)
  }

  @Test("a hop while closing is remembered: the closing record says opening, closed reopens under the next generation")
  func reopenAfterClose() throws {
    var m = openWindow()
    _ = m.handle(.expired(1), now: t0 + window)
    let reopening = Machine.State.closing(1, cause: .reopen)
    let hop = try row(&m, .openRequested(inForeground: true), at: t0 + window + 1, lands: reopening, asks: [])
    #expect(hop.window == .closing && hop.reason == .opening && !hop.micLive)
    #expect(m.handle(.openRequested(inForeground: true), now: t0 + window + 2).isEmpty, "remembered once")
    let asks: [Effect] = [.endBackgroundTask, .cancelExpiry, .activateSession, .openSource(2)]
    let opening = try row(&m, .closed(1), at: t0 + window + 3, lands: .opening(2), asks: asks)
    #expect(opening.window == .opening && opening.reason == .opening && opening.windowUntil == nil)
    #expect(m.handle(.closed(1), now: t0 + window + 4) == [.log("\(Machine.staleGenerationLog) 1 (current 2)")])
  }

  @Test("a reopen during close yields exactly one openSource, with the new generation")
  func reopenOpensSourceOnce() {
    var m = closingWindow()
    var effects = m.handle(.openRequested(inForeground: true), now: t0 + 1)
    effects += m.handle(.openRequested(inForeground: true), now: t0 + 2)
    effects += m.handle(.closed(1), now: t0 + 3)
    effects += m.handle(.opened(2), now: t0 + 4)
    let opens = effects.compactMap { if case .openSource(let gen) = $0 { gen } else { nil } }
    #expect(opens == [2] && m.state == .open(2, idle: .held, utterance: false))
  }

  @Test("while closing, a hop from the background and a foreground change nothing")
  func closingIgnoresTheRest() {
    var m = closingWindow()
    #expect(m.handle(.openRequested(inForeground: false), now: t0 + 1).isEmpty)
    #expect(m.handle(.foregrounded(turnedOff: false), now: t0 + 1).isEmpty)
    #expect(m.handle(.foregrounded(turnedOff: true), now: t0 + 1).isEmpty)
    #expect(m.state == .closing(1, cause: .stop))
    _ = m.handle(.closed(1), now: t0 + 2)
    #expect(m.state == .closed)
  }

  @Test("a Stop after a hop while closing takes the reopen back: closed rests, saying the session is off")
  func stopCancelsReopen() throws {
    var m = closingWindow()
    _ = m.handle(.openRequested(inForeground: true), now: t0 + 1)
    let stop = try row(&m, .closeRequested, at: t0 + 2, lands: .closing(1, cause: .stop), asks: [])
    #expect(stop.reason == .sessionOff)
    #expect(m.handle(.closeRequested, now: t0 + 3).isEmpty)
    let rest = try row(&m, .closed(1), at: t0 + 4, lands: .closed, asks: [.endBackgroundTask, .cancelExpiry])
    #expect(rest.reason == .sessionOff)
  }

  @Test("heartbeat while closing publishes closing, the mic not live")
  func heartbeatWhileClosing() throws {
    var m = closingWindow()
    let beat = try record(m.heartbeat(micLive: true, now: t0 + 1))
    #expect(beat.window == .closing && !beat.micLive && beat.reason == .sessionOff)
    #expect(m.state == .closing(1, cause: .stop))
  }

  @Test("windowMinutesChanged while open moves the end to the new length from now; a dictation's floor still holds")
  func windowMinutesChangedWhileOpen() throws {
    var m = openWindow()
    let five: TimeInterval = 5 * 60
    let asks: [Effect] = [.scheduleExpiry(t0 + 10 + five, 1)]
    let record = try row(&m, .windowMinutesChanged(5), at: t0 + 10, lands: held, asks: asks)
    #expect(record.windowUntil == t0 + 10 + five && record.micLive && m.windowMinutes == 5)
    #expect(actions(m.handle(.utteranceStarted(1), now: t0 + 20)) == [.scheduleExpiry(t0 + 20 + maxAudio, 1)])
    #expect(actions(m.handle(.utteranceEnded(1), now: t0 + 30)) == [.scheduleExpiry(t0 + 30 + five, 1)])
    var dictating = openWindow(dictating: true)
    #expect(five < maxAudio)
    let floored = dictating.handle(.windowMinutesChanged(5), now: t0 + 10)
    #expect(actions(floored) == [.scheduleExpiry(t0 + 10 + maxAudio, 1)])
    #expect(Machine.Event.windowMinutesChanged(5).generation == nil)
  }

  @Test("windowMinutesChanged to until-stopped while open cancels the expiry; back to minutes schedules it again")
  func windowMinutesChangedToUntilStopped() throws {
    var m = openWindow()
    let untilStopped = Machine.Event.windowMinutesChanged(Machine.untilStopped)
    let record = try row(&m, untilStopped, at: t0 + 10, lands: held, asks: [.cancelExpiry])
    #expect(record.windowUntil == nil && m.windowUntil == nil)
    #expect(actions(m.handle(.utteranceStarted(1), now: t0 + 20)).isEmpty)
    _ = m.handle(.utteranceEnded(1), now: t0 + 25)
    let asks: [Effect] = [.scheduleExpiry(t0 + 30 + window, 1)]
    let again = try row(&m, .windowMinutesChanged(minutes), at: t0 + 30, lands: held, asks: asks)
    #expect(again.windowUntil == t0 + 30 + window)
  }

  @Test("windowMinutesChanged in any other state is only stored, for the next expiry")
  func windowMinutesChangedStored() {
    var closed = fresh()
    #expect(closed.handle(.windowMinutesChanged(5), now: t0).isEmpty && closed.windowMinutes == 5)
    _ = closed.handle(.openRequested(inForeground: true), now: t0 + 1)
    #expect(actions(closed.handle(.opened(1), now: t0 + 2)) == [.scheduleExpiry(t0 + 2 + 5 * 60, 1)])
    var interrupted = interruptedWindow()
    #expect(interrupted.handle(.windowMinutesChanged(5), now: t0 + 1).isEmpty && interrupted.windowUntil == t0 + window)
    let resumed = actions(interrupted.handle(.resumed(1), now: t0 + 2))
    #expect(resumed == [.endBackgroundTask, .scheduleExpiry(t0 + window, 1)], "the old end, until the next word")
    var opening = openWindow(opened: false)
    #expect(opening.handle(.windowMinutesChanged(5), now: t0 + 1).isEmpty && opening.state == .opening(1))
    var closing = closingWindow()
    #expect(closing.handle(.windowMinutesChanged(5), now: t0 + 1).isEmpty && closing.windowMinutes == 5)
  }

  @Test("a source lost while opening is carried: opened lands interrupted, a background task held, the mic not live")
  func lossWhileOpening() throws {
    var m = openWindow(opened: false)
    let lost = m.handle(.interruptionBegan(1, .interrupted), now: t0 + 1)
    #expect(lost.count == 1 && m.state == .opening(1))
    #expect(lost.contains { if case .log = $0 { true } else { false } })
    let asks: [Effect] = [.scheduleExpiry(t0 + 2 + window, 1), .beginBackgroundTask]
    let record = try row(&m, .opened(1), at: t0 + 2, lands: paused, asks: asks)
    #expect(record.window == .interrupted && !record.micLive && record.reason == .interrupted)
    #expect(record.windowUntil == t0 + 2 + window && record.notReady(now: t0 + 2) == .interrupted)
    let back: [Effect] = [.endBackgroundTask, .scheduleExpiry(t0 + 2 + window, 1)]
    let resumed = try row(&m, .resumed(1), at: t0 + 3, lands: held, asks: back)
    #expect(resumed.micLive && resumed.isReady(now: t0 + 3))
    var died = openWindow(opened: false)
    _ = died.handle(.sourceDied(1, .micBusy), now: t0 + 1)
    let effects = died.handle(.opened(1), now: t0 + 2)
    #expect(died.state == .interrupted(1, reason: .micBusy, resumable: true))
    #expect(actions(effects) == asks && records(effects).first?.reason == .micBusy)
  }

  @Test("a loss while opening is forgotten by openFailed and by a Stop: the next window opens clean")
  func lossWhileOpeningForgotten() throws {
    var failed = openWindow(opened: false)
    _ = failed.handle(.interruptionBegan(1, .interrupted), now: t0 + 1)
    let asks: [Effect] = [.closeSource(1), standDown]
    let record = try row(&failed, .openFailed(1, .micDenied), at: t0 + 2, lands: .closed, asks: asks)
    #expect(record.reason == .micDenied)
    _ = failed.handle(.openRequested(inForeground: true), now: t0 + 3)
    let clean = Machine.State.open(2, idle: .held, utterance: false)
    try row(&failed, .opened(2), at: t0 + 4, lands: clean, asks: [.scheduleExpiry(t0 + 4 + window, 2)])
    var stopped = openWindow(opened: false)
    _ = stopped.handle(.sourceDied(1, .micBusy), now: t0 + 1)
    _ = stopped.handle(.closeRequested, now: t0 + 2)
    _ = stopped.handle(.closed(1), now: t0 + 3)
    _ = stopped.handle(.openRequested(inForeground: true), now: t0 + 4)
    _ = stopped.handle(.opened(2), now: t0 + 5)
    #expect(stopped.state == clean)
  }

  @Test("a refresh publishes the last heartbeat's micLive, not true")
  func refreshPublishesLastMicLive() throws {
    var m = openWindow()
    #expect(m.lastMicLive)
    _ = m.heartbeat(micLive: false, now: t0 + 5)
    #expect(!m.lastMicLive)
    let quiet = try record(m.handle(.openRequested(inForeground: true), now: t0 + 6))
    #expect(!quiet.micLive && quiet.window == .open && quiet.notReady(now: t0 + 6) == .micBusy)
    _ = m.heartbeat(micLive: true, now: t0 + 10)
    let live = try record(m.handle(.openRequested(inForeground: true), now: t0 + 11))
    #expect(live.micLive && live.isReady(now: t0 + 11))
    _ = m.handle(.interruptionBegan(1, .interrupted), now: t0 + 12)
    _ = m.heartbeat(micLive: true, now: t0 + 13)
    #expect(!m.lastMicLive, "a beat while interrupted never says live")
    _ = m.handle(.resumed(1), now: t0 + 14)
    #expect(m.lastMicLive)
    #expect(try record(m.handle(.openRequested(inForeground: true), now: t0 + 15)).micLive)
  }

  @Test("the session turned off while interrupted logs the same line as a Stop there: the session stays active")
  func turnedOffWhileInterruptedLogs() {
    var foregrounded = interruptedWindow()
    let fromForeground = foregrounded.handle(.foregrounded(turnedOff: true), now: t0 + 1)
    var stopped = interruptedWindow()
    let fromStop = stopped.handle(.closeRequested, now: t0 + 1)
    let line = Effect.log(Machine.stopWhileInterruptedLog)
    #expect(fromForeground.last == line && fromStop.last == line)
    #expect(actions(fromForeground) == actions(fromStop) && foregrounded.state == stopped.state)
  }

  @Test("mediaReset mid-dictation releases the words before the source closes")
  func mediaResetMidDictation() {
    var m = openWindow(dictating: true)
    let effects = actions(m.handle(.mediaReset(1), now: t0 + 1))
    #expect(effects == [.endUtterance(keepWords: true), .closeSource(1), standDown])
    #expect(m.state == .closing(1, cause: .mediaReset))
  }

  @Test("open + foregrounded(false) and opening + utteranceStarted change nothing")
  func foregroundAndEarlyPressAreNoOps() {
    var open = openWindow()
    #expect(open.handle(.foregrounded(turnedOff: false), now: t0 + 1).isEmpty && open.state == held)
    var opening = openWindow(opened: false)
    #expect(opening.handle(.utteranceStarted(1), now: t0 + 1).isEmpty && opening.state == .opening(1))
  }
}
