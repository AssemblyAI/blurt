import Foundation

// MARK: - The listening window's state machine
//
// One owner for the window's lifecycle, with no clock, no audio and no store
// of its own: the interpreter (`ListeningWindow`) feeds it what happened as
// events and carries out what it answers as effects, so every transition is
// a value a test can drive without a simulator. The causes, states, events
// and effects are in `ListeningWindowMachine+Types.swift`.

/// The app's listening window as a pure state machine. Every opening of the
/// source gets a generation, and every event about the source carries the one
/// it belongs to: a timer or a callback from a window that has since closed is
/// logged as stale instead of acting on the next one. The records it publishes
/// (`ListeningState`) are the keyboard's whole picture of the window, so
/// `sequence` climbs on every publish and the lease is always a real date.
package nonisolated struct ListeningWindowMachine: Sendable {
  /// One per opening of the source; `Effect.openSource` carries the new one.
  package typealias Generation = UInt64

  /// `windowMinutes` of this: the window runs until stopped, with no end and no expiry.
  package static let untilStopped = 0
  package static let secondsPerMinute: TimeInterval = 60
  /// How the log names an event from a window that has since closed.
  package static let staleGenerationLog = "stale gen"
  /// The log's line for an open asked for from the background.
  package static let openRefusedLog = "open refused: the app is not in front"
  /// The log's line for the session turned off while interrupted, by Stop or
  /// by the switch: the session is left active, since deactivating during a
  /// call throws (`Effect.deactivateSession(skipIfInterrupted:)`).
  package static let stopWhileInterruptedLog =
    "stop while interrupted: the audio session stays active until the interruption ends"

  package let launchID: UUID
  /// `SharedStore.windowMinutes` as Settings last set it (`Event.windowMinutesChanged`):
  /// how long the window stays open after the last word.
  package private(set) var windowMinutes: Int
  /// `SyncSTTLimits.maxAudioSeconds`: a dictation's start holds the window open
  /// at least this long, so a short window can't end a long dictation partway.
  package let maxAudioSeconds: TimeInterval
  package private(set) var state: State = .closed
  /// Bumped on every publish; the keyboard orders records by it.
  package private(set) var sequence: UInt64 = 0
  package private(set) var idle: ListeningState.Idle
  /// The window's end, kept across an interruption so a resume can put the
  /// expiry back where it was.
  package private(set) var windowUntil: Date?
  /// `micLive` as the last heartbeat read it off the source, which is what a
  /// refresh republishes. True as the source comes up (opened, resumed): the
  /// first beat has not read it yet.
  package private(set) var lastMicLive = false
  private var lastGeneration: Generation = 0
  /// Why the window closed, as its record said it (the failed open's reason,
  /// the refusal's, the cause's): every heartbeat while closed says it again,
  /// since the state no longer holds it.
  private var closedReason: FailureReason?
  /// A hop landed while the source was closing: `closed` reopens instead of resting.
  private var reopenWanted = false
  /// The source was lost (an interruption, or it died) while still opening:
  /// `opened` lands interrupted with this reason, not open.
  private var lossWhileOpening: FailureReason?

  package init(launchID: UUID, windowMinutes: Int, maxAudioSeconds: TimeInterval, idle: ListeningState.Idle = .held) {
    self.launchID = launchID
    self.windowMinutes = windowMinutes
    self.maxAudioSeconds = maxAudioSeconds
    self.idle = idle
  }

  /// The transition table. An event about another generation changes
  /// nothing; every change of state publishes a record.
  package mutating func handle(_ event: Event, now: Date) -> [Effect] {
    if let gen = event.generation, gen != state.generation {
      let current = state.generation.map(String.init) ?? "none"
      return [.log("\(Self.staleGenerationLog) \(gen) (current \(current))")]
    }
    switch event {
    case .openRequested(let inForeground): return openRequested(inForeground: inForeground, now: now)
    case .closeRequested: return closeRequested(now: now)
    case .foregrounded(let turnedOff): return foregrounded(turnedOff: turnedOff, now: now)
    case .windowMinutesChanged(let minutes): return windowMinutesChanged(to: minutes, now: now)
    case .idleChanged(_, let idle): return idleChanged(to: idle, now: now)
    default: return fromSource(event, now: now)
    }
  }

  /// The heartbeat's record while a window exists: the same state with the
  /// lease renewed and `micLive` as the interpreter just read it off the
  /// source — true only while the window is open, whatever the source says
  /// otherwise. A closed record keeps saying why it closed.
  package mutating func heartbeat(micLive: Bool, now: Date) -> [Effect] {
    lastMicLive = micLive && state.isOpen
    return [publish(now: now, micLive: lastMicLive)]
  }

  /// The heartbeat's record with no window: the one the interpreter last
  /// published — the launch's, or the closed one a window left — renewed as
  /// `ListeningState.renewed` says it, the lease moved on and the reason kept,
  /// so the keyboard reads an app that is alive and off, never one suspended.
  /// The sequence stays this machine's to give out: the next window's first
  /// record follows the beats, so the keyboard's order holds.
  package mutating func heartbeat(renewing record: ListeningState, now: Date) -> [Effect] {
    let renewed = record.renewed(micLive: false, at: now)
    sequence = max(sequence, renewed.sequence)
    return [.publish(renewed)]
  }

  /// The record for the state as it stands this instant, as the next publish
  /// would say it, the sequence unmoved: what the interpreter routes a command
  /// on between publishes, since the record it last published trails the
  /// effects that follow a transition.
  package func current(now: Date) -> ListeningState {
    record(sequence: sequence, now: now, micLive: state.isOpen && lastMicLive)
  }
}

nonisolated extension ListeningWindowMachine {
  // MARK: The app's own events

  /// The foreground gate lives here: iOS refuses to start capture from the
  /// background, so an open asked for there is refused with the reason the
  /// keyboard needs to hop. A window already open is refreshed, never
  /// reopened; one that is interrupted is reopened under a new generation;
  /// one that is closing is reopened once it has closed.
  private mutating func openRequested(inForeground: Bool, now: Date) -> [Effect] {
    switch state {
    case .closed:
      guard inForeground else {
        closedReason = .needsForeground
        return [publish(now: now), .log(Self.openRefusedLog)]
      }
      return open(now: now)
    case .open(_, _, let utterance):
      return expiry(from: now, floor: utterance ? maxAudioSeconds : 0) + [publish(now: now, micLive: lastMicLive)]
    case .interrupted(let gen, _, _):
      guard inForeground else { return [] }
      return [.closeSource(gen), .endBackgroundTask] + open(now: now)
    case .closing(let gen, _):
      guard inForeground, !reopenWanted else { return [] }
      reopenWanted = true
      state = .closing(gen, cause: .reopen)
      return [publish(now: now)]
    case .opening:
      return []
    }
  }

  /// The switch or Stop: the user's word, so a dictation in flight is
  /// cancelled rather than released, and a reopen a hop asked for while
  /// closing is taken back.
  private mutating func closeRequested(now: Date) -> [Effect] {
    switch state {
    case .closed:
      return []
    case .closing(let gen, _):
      guard reopenWanted else { return [] }
      reopenWanted = false
      state = .closing(gen, cause: .stop)
      return [publish(now: now)]
    case .opening(let gen), .open(let gen, _, _):
      return close(gen, cause: .stop, keepWords: false, now: now)
    case .interrupted(let gen, _, _):
      return close(gen, cause: .stop, keepWords: false, now: now) + [.log(Self.stopWhileInterruptedLog)]
    }
  }

  /// Only an interrupted window has anything to do with the app coming to
  /// the front: the source may be started again now, unless the user turned
  /// the session off meanwhile, in which case the off switch wins.
  private mutating func foregrounded(turnedOff: Bool, now: Date) -> [Effect] {
    guard case .interrupted(let gen, _, _) = state else { return [] }
    if turnedOff {
      return close(gen, cause: .stop, keepWords: false, now: now) + [.log(Self.stopWhileInterruptedLog)]
    }
    return [.tryResume(gen, mayStart: true)]
  }

  /// Settings' change, applied live: an open window's end moves to the new
  /// length from now (a dictation's floor still holds), and until-stopped
  /// takes the running timer away — an interrupted window's too, which runs
  /// on through the pause and would end it, or end it the moment it resumed.
  /// Any other state only keeps the number for its next expiry.
  private mutating func windowMinutesChanged(to minutes: Int, now: Date) -> [Effect] {
    windowMinutes = minutes
    switch state {
    case .open(_, _, let utterance):
      let rescheduled = expiry(from: now, floor: utterance ? maxAudioSeconds : 0)
      return (rescheduled.isEmpty ? [.cancelExpiry] : rescheduled) + [publish(now: now)]
    case .interrupted where minutes <= Self.untilStopped && windowUntil != nil:
      windowUntil = nil
      return [.cancelExpiry, publish(now: now)]
    case .closed, .opening, .closing, .interrupted:
      return []
    }
  }

  private mutating func idleChanged(to idle: ListeningState.Idle, now: Date) -> [Effect] {
    self.idle = idle
    if case .open(let gen, _, let utterance) = state { state = .open(gen, idle: idle, utterance: utterance) }
    return [publish(now: now)]
  }

  // MARK: The source's, the timer's and the session's events

  private mutating func fromSource(_ event: Event, now: Date) -> [Effect] {
    switch event {
    case .opened, .openFailed: return whileOpening(event, now: now)
    case .utteranceStarted, .utteranceEnded: return utterance(event, now: now)
    case .interruptionBegan(_, let reason), .sourceDied(_, let reason):
      return lostSource(event, reason: reason, now: now)
    case .interruptionEnded, .resumed, .resumeFailed: return whileInterrupted(event, now: now)
    case .mediaReset, .expired: return ending(event, now: now)
    case .closed: return closed(now: now)
    default: return []
    }
  }

  /// The source came up, or did not. A loss that landed while it was still
  /// opening is carried: the window opens interrupted, waiting to resume, so
  /// a press is not promised a microphone a call already holds.
  private mutating func whileOpening(_ event: Event, now: Date) -> [Effect] {
    guard case .opening(let gen) = state else { return [] }
    switch event {
    case .opened:
      if let reason = lossWhileOpening {
        lossWhileOpening = nil
        state = .interrupted(gen, reason: reason, resumable: true)
        return expiry(from: now) + [.beginBackgroundTask, publish(now: now)]
      }
      state = .open(gen, idle: idle, utterance: false)
      lastMicLive = true
      return expiry(from: now) + [publish(now: now)]
    case .openFailed(_, let reason):
      state = .closed
      lossWhileOpening = nil
      closedReason = reason
      return [.closeSource(gen), .deactivateSession(skipIfInterrupted: false), publish(now: now)]
    default:
      return []
    }
  }

  /// The window's lifetime counts from the last word: a dictation's end
  /// pushes the expiry out, and its start holds it past the longest a
  /// dictation can run.
  private mutating func utterance(_ event: Event, now: Date) -> [Effect] {
    guard case .open(let gen, _, let inFlight) = state else { return [] }
    switch event {
    case .utteranceStarted where !inFlight:
      state = .open(gen, idle: idle, utterance: true)
      return expiry(from: now, floor: maxAudioSeconds) + [publish(now: now)]
    case .utteranceEnded where inFlight:
      state = .open(gen, idle: idle, utterance: false)
      return expiry(from: now) + [publish(now: now)]
    default:
      return []
    }
  }

  /// A call, Siri, an alarm, or the capture session dying under us: the dictation
  /// in flight is released with what it has, and the window waits to resume rather
  /// than closing. An interruption holds a background task for the resume to run in.
  /// While still opening, the loss is remembered for `opened` to land on.
  private mutating func lostSource(_ event: Event, reason: FailureReason, now: Date) -> [Effect] {
    switch state {
    case .opening:
      lossWhileOpening = reason
      return [.log("source lost while opening (\(reason.rawValue)): opened lands interrupted")]
    case .open(let gen, _, let inFlight):
      var effects: [Effect] = inFlight ? [.endUtterance(keepWords: true)] : []
      state = .interrupted(gen, reason: reason, resumable: true)
      if case .interruptionBegan = event { effects.append(.beginBackgroundTask) }
      effects.append(publish(now: now))
      return effects
    case .closed, .interrupted, .closing:
      return []
    }
  }

  /// Resuming never starts the source from the background: the interruption's
  /// end earns a poll, the next foreground a start. A failed resume keeps the
  /// window, with the reason the keyboard shows, until the next foreground.
  private mutating func whileInterrupted(_ event: Event, now: Date) -> [Effect] {
    guard case .interrupted(let gen, _, let resumable) = state else { return [] }
    switch event {
    case .interruptionEnded(_, let shouldResume):
      return shouldResume && resumable ? [.tryResume(gen, mayStart: false)] : []
    case .resumed:
      state = .open(gen, idle: idle, utterance: false)
      lastMicLive = true
      let expiry = windowUntil.map { [Effect.scheduleExpiry($0, gen)] } ?? []
      return [.endBackgroundTask] + expiry + [publish(now: now)]
    case .resumeFailed(_, let reason):
      state = .interrupted(gen, reason: reason, resumable: false)
      return [.endBackgroundTask, publish(now: now)]
    default:
      return []
    }
  }

  /// The window ending on its own, open or interrupted: its time ran out, or
  /// media services were reset under it.
  private mutating func ending(_ event: Event, now: Date) -> [Effect] {
    guard let gen = state.generation, [.open, .interrupted].contains(state.window) else { return [] }
    switch event {
    case .mediaReset: return close(gen, cause: .mediaReset, keepWords: true, now: now)
    case .expired: return close(gen, cause: .expiry, keepWords: true, now: now)
    default: return []
    }
  }

  /// The source is closed. The window rests with the cause's reason — or,
  /// when a hop landed while it was closing, opens again at once.
  private mutating func closed(now: Date) -> [Effect] {
    guard case .closing(_, let cause) = state else { return [] }
    let standDown: [Effect] = [.endBackgroundTask, .cancelExpiry]
    if reopenWanted {
      reopenWanted = false
      return standDown + open(now: now)
    }
    state = .closed
    closedReason = cause.reason
    return standDown + [publish(now: now)]
  }

  // MARK: The moves the rows share

  /// A new generation: the session up, the source opening under it.
  private mutating func open(now: Date) -> [Effect] {
    lastGeneration += 1
    state = .opening(lastGeneration)
    windowUntil = nil
    closedReason = nil
    lossWhileOpening = nil
    return [.activateSession, .openSource(lastGeneration), publish(now: now)]
  }

  /// Into `closing`: the closing record goes out first, before any of the
  /// work — ending the dictation and closing the source are awaited, and a
  /// press read meanwhile must find a window that no longer records — then
  /// the dictation in flight ends (while the feed still holds its audio), the
  /// source closes and the session stands down — left active if the window
  /// was interrupted, since deactivating during a call throws. `closed(gen)`
  /// finishes it with one more record.
  private mutating func close(_ gen: Generation, cause: Cause, keepWords: Bool, now: Date) -> [Effect] {
    let ending: [Effect] = state.utterance ? [.endUtterance(keepWords: keepWords)] : []
    let wasInterrupted = state.window == .interrupted
    state = .closing(gen, cause: cause)
    windowUntil = nil
    lossWhileOpening = nil
    return [publish(now: now)] + ending
      + [.closeSource(gen), .deactivateSession(skipIfInterrupted: wasInterrupted)]
  }

  /// The window's end from now — `windowMinutes` of silence, or `floor` if
  /// that is longer — and the effect that schedules it. None when the window
  /// runs until stopped.
  private mutating func expiry(from now: Date, floor: TimeInterval = 0) -> [Effect] {
    guard windowMinutes > Self.untilStopped, let gen = state.generation else {
      windowUntil = nil
      return []
    }
    let until = now.addingTimeInterval(max(TimeInterval(windowMinutes) * Self.secondsPerMinute, floor))
    windowUntil = until
    return [.scheduleExpiry(until, gen)]
  }

  /// Why a press would not record, as the record says it: the state's, or
  /// while closed the reason it closed for, which the state no longer holds.
  private var publishedReason: FailureReason? {
    if case .closed = state { closedReason ?? state.reason } else { state.reason }
  }

  /// The record for the state as it stands, one sequence number on. `micLive`
  /// defaults to what the state says.
  private mutating func publish(now: Date, micLive: Bool? = nil) -> Effect {
    sequence += 1
    return .publish(record(sequence: sequence, now: now, micLive: micLive ?? state.isOpen))
  }

  /// The state as a record, under the given sequence number.
  private func record(sequence: UInt64, now: Date, micLive: Bool) -> ListeningState {
    ListeningState(
      launchID: launchID, sequence: sequence, window: state.window, idle: idle, micLive: micLive,
      windowUntil: windowUntil, utterance: state.utterance, reason: publishedReason, writtenAt: now)
  }
}
