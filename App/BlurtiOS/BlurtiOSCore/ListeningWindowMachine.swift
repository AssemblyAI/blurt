import Foundation

// MARK: - The listening window's state machine
//
// One owner for the window's lifecycle, with no clock, no audio and no store
// of its own: the interpreter (`ListeningWindow`) feeds it what happened as
// events and carries out what it answers as effects, so every transition is
// a value a test can drive without a simulator.

/// The app's listening window as a pure state machine. Every opening of the
/// source gets a generation, and every event about the source carries the one
/// it belongs to: a timer or a callback from a window that has since closed is
/// logged as stale instead of acting on the next one. The records it publishes
/// (`ListeningState`) are the keyboard's whole picture of the window, so
/// `sequence` climbs on every publish and the lease is always a real date.
package nonisolated struct ListeningWindowMachine: Sendable {
  /// One per opening of the source; `Effect.openSource` carries the new one.
  package typealias Generation = UInt64

  /// Why a window is closing or closed: for the log, and for the closed record's reason.
  package nonisolated enum Cause: Sendable, Equatable {
    case expiry
    case stop
    case interrupted
    case died
    case openFailed
    case mediaReset
    case reopen

    /// How the closed record says it.
    package var reason: FailureReason {
      switch self {
      case .expiry, .stop: .sessionOff
      case .interrupted: .interrupted
      case .died, .openFailed: .micBusy
      case .mediaReset: .mediaReset
      case .reopen: .opening
      }
    }
  }

  package nonisolated enum State: Sendable, Equatable {
    case closed
    case opening(Generation)
    case open(Generation, idle: ListeningState.Idle, utterance: Bool)
    /// `resumable`: a poll when the interruption ends may bring the source
    /// back. False once a resume has failed; then only the next foreground
    /// tries again.
    case interrupted(Generation, reason: FailureReason, resumable: Bool)
    case closing(Generation, cause: Cause)

    package var generation: Generation? {
      switch self {
      case .closed: nil
      case .opening(let gen), .open(let gen, _, _), .interrupted(let gen, _, _), .closing(let gen, _): gen
      }
    }

    package var window: ListeningState.Window {
      switch self {
      case .closed: .closed
      case .opening: .opening
      case .open: .open
      case .interrupted: .interrupted
      case .closing: .closing
      }
    }

    /// The source is open: the only state in which a press records.
    package var isOpen: Bool {
      if case .open = self { true } else { false }
    }

    /// A dictation is in flight.
    package var utterance: Bool {
      if case .open(_, _, true) = self { true } else { false }
    }

    /// Why a press would not record, as the record says it; nil while open.
    package var reason: FailureReason? {
      switch self {
      case .closed: .sessionOff
      case .opening: .opening
      case .open: nil
      case .interrupted(_, let reason, _): reason
      case .closing(_, let cause): cause.reason
      }
    }
  }

  /// What happened. Events about the source carry the generation they are about;
  /// the app's own (`openRequested`, `closeRequested`, `foregrounded`) carry none.
  package nonisolated enum Event: Sendable, Equatable {
    case openRequested(inForeground: Bool)
    case opened(Generation)
    case openFailed(Generation, FailureReason)
    case utteranceStarted(Generation)
    case utteranceEnded(Generation)
    case interruptionBegan(Generation, FailureReason)
    case interruptionEnded(Generation, shouldResume: Bool)
    /// The app came to the front; `turnedOff` is the session switch's word.
    case foregrounded(turnedOff: Bool)
    case resumed(Generation)
    case resumeFailed(Generation, FailureReason)
    case sourceDied(Generation, FailureReason)
    case mediaReset(Generation)
    case expired(Generation)
    case closeRequested
    case closed(Generation)
    case idleChanged(Generation, ListeningState.Idle)

    package var generation: Generation? {
      switch self {
      case .openRequested, .foregrounded, .closeRequested: nil
      case .opened(let gen), .openFailed(let gen, _), .utteranceStarted(let gen), .utteranceEnded(let gen),
        .interruptionBegan(let gen, _), .interruptionEnded(let gen, _), .resumed(let gen), .resumeFailed(let gen, _),
        .sourceDied(let gen, _), .mediaReset(let gen), .expired(let gen), .closed(let gen), .idleChanged(let gen, _):
        gen
      }
    }
  }

  /// What to do about it, in order. The interpreter owns the audio session, the
  /// source, the timers, the background task and the store; this only names it.
  package nonisolated enum Effect: Sendable, Equatable {
    case activateSession
    case openSource(Generation)
    /// `mayStart`: the app is in front, so the source may be started outright;
    /// otherwise only reactivate and poll for it coming back on its own.
    case tryResume(Generation, mayStart: Bool)
    /// The dictation in flight ends: released with its words, or cancelled.
    case endUtterance(keepWords: Bool)
    case closeSource(Generation)
    /// `skipIfInterrupted`: deactivating during a call throws, so leave it.
    case deactivateSession(skipIfInterrupted: Bool)
    case scheduleExpiry(Date, Generation)
    case cancelExpiry
    case beginBackgroundTask
    case endBackgroundTask
    case publish(ListeningState)
    case log(String)
  }

  /// `windowMinutes` of this: the window runs until stopped, with no end and no expiry.
  package static let untilStopped = 0
  package static let secondsPerMinute: TimeInterval = 60
  /// How the log names an event from a window that has since closed.
  package static let staleGenerationLog = "stale gen"

  package let launchID: UUID
  /// `SharedStore.windowMinutes`: how long the window stays open after the last word.
  package let windowMinutes: Int
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
  private var lastGeneration: Generation = 0

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
    case .idleChanged(_, let idle): return idleChanged(to: idle, now: now)
    default: return fromSource(event, now: now)
    }
  }

  /// The heartbeat's record: the same state with the lease renewed and
  /// `micLive` as the interpreter just read it off the source — true only
  /// while the window is open, whatever the source says otherwise.
  package mutating func heartbeat(micLive: Bool, now: Date) -> [Effect] {
    [publish(now: now, micLive: micLive && state.isOpen)]
  }
}

nonisolated extension ListeningWindowMachine {
  // MARK: The app's own events

  /// The foreground gate lives here: iOS refuses to start capture from the
  /// background, so an open asked for there is refused with the reason the
  /// keyboard needs to hop. A window already open is refreshed, never
  /// reopened; one that is interrupted is reopened under a new generation.
  private mutating func openRequested(inForeground: Bool, now: Date) -> [Effect] {
    switch state {
    case .closed:
      guard inForeground else {
        return [publish(now: now, reason: .needsForeground), .log("open refused: the app is not in front")]
      }
      return open(now: now)
    case .open(_, _, let utterance):
      return expiry(from: now, floor: utterance ? maxAudioSeconds : 0) + [publish(now: now)]
    case .interrupted(let gen, _, _):
      guard inForeground else { return [] }
      return [.closeSource(gen), .endBackgroundTask] + open(now: now)
    case .opening, .closing:
      return []
    }
  }

  /// The switch or Stop: the user's word, so a dictation in flight is
  /// cancelled rather than released.
  private mutating func closeRequested(now: Date) -> [Effect] {
    switch state {
    case .closed, .closing:
      return []
    case .opening(let gen), .open(let gen, _, _):
      return close(gen, cause: .stop, keepWords: false, now: now)
    case .interrupted(let gen, _, _):
      return close(gen, cause: .stop, keepWords: false, now: now)
        + [.log("stop while interrupted: the audio session stays active until the interruption ends")]
    }
  }

  /// Only an interrupted window has anything to do with the app coming to
  /// the front: the source may be started again now, unless the user turned
  /// the session off meanwhile, in which case the off switch wins.
  private mutating func foregrounded(turnedOff: Bool, now: Date) -> [Effect] {
    guard case .interrupted(let gen, _, _) = state else { return [] }
    if turnedOff { return close(gen, cause: .stop, keepWords: false, now: now) }
    return [.tryResume(gen, mayStart: true)]
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
    case .interruptionBegan, .sourceDied: return lostSource(event, now: now)
    case .interruptionEnded, .resumed, .resumeFailed: return whileInterrupted(event, now: now)
    case .mediaReset, .expired: return ending(event, now: now)
    case .closed: return closed(now: now)
    default: return []
    }
  }

  private mutating func whileOpening(_ event: Event, now: Date) -> [Effect] {
    guard case .opening(let gen) = state else { return [] }
    switch event {
    case .opened:
      state = .open(gen, idle: idle, utterance: false)
      return expiry(from: now) + [publish(now: now)]
    case .openFailed(_, let reason):
      state = .closed
      return [.closeSource(gen), .deactivateSession(skipIfInterrupted: false), publish(now: now, reason: reason)]
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
  private mutating func lostSource(_ event: Event, now: Date) -> [Effect] {
    guard case .open(let gen, _, let inFlight) = state else { return [] }
    var effects: [Effect] = inFlight ? [.endUtterance(keepWords: true)] : []
    switch event {
    case .interruptionBegan(_, let reason):
      state = .interrupted(gen, reason: reason, resumable: true)
      effects.append(.beginBackgroundTask)
    case .sourceDied(_, let reason):
      state = .interrupted(gen, reason: reason, resumable: true)
    default:
      return []
    }
    effects.append(publish(now: now))
    return effects
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

  private mutating func closed(now: Date) -> [Effect] {
    guard case .closing(_, let cause) = state else { return [] }
    state = .closed
    return [.endBackgroundTask, .cancelExpiry, publish(now: now, reason: cause.reason)]
  }

  // MARK: The moves the rows share

  /// A new generation: the session up, the source opening under it.
  private mutating func open(now: Date) -> [Effect] {
    lastGeneration += 1
    state = .opening(lastGeneration)
    windowUntil = nil
    return [.activateSession, .openSource(lastGeneration), publish(now: now)]
  }

  /// Into `closing`: the dictation in flight ends first (while the feed still
  /// holds its audio), then the source closes and the session stands down —
  /// left active if the window was interrupted, since deactivating during a
  /// call throws. `closed(gen)` finishes it.
  private mutating func close(_ gen: Generation, cause: Cause, keepWords: Bool, now: Date) -> [Effect] {
    var effects: [Effect] = state.utterance ? [.endUtterance(keepWords: keepWords)] : []
    let wasInterrupted = state.window == .interrupted
    state = .closing(gen, cause: cause)
    windowUntil = nil
    effects += [.closeSource(gen), .deactivateSession(skipIfInterrupted: wasInterrupted), publish(now: now)]
    return effects
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

  /// The record for the state as it stands, one sequence number on. `micLive`
  /// and `reason` default to what the state says; a closed record may carry
  /// the reason it closed for, which the state no longer holds.
  private mutating func publish(now: Date, micLive: Bool? = nil, reason: FailureReason? = nil) -> Effect {
    sequence += 1
    return .publish(
      ListeningState(
        launchID: launchID, sequence: sequence, window: state.window, idle: idle,
        micLive: micLive ?? state.isOpen, windowUntil: windowUntil, utterance: state.utterance,
        reason: reason ?? state.reason, writtenAt: now))
  }
}
