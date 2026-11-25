import Foundation

// MARK: - The moves the rows share
//
// Opening, closing, the expiry and the record: what the rows of the table in
// `ListeningWindowMachine.swift` end in.

nonisolated extension ListeningWindowMachine {
  /// Why a press would not record, as the record says it: the state's, or
  /// while closed the reason it closed for, which the state no longer holds.
  var publishedReason: FailureReason? {
    if case .closed = state { closedReason ?? state.reason } else { state.reason }
  }

  /// A new generation: the session up, the source opening under it.
  mutating func open(now: Date) -> [Effect] {
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
  mutating func close(_ gen: Generation, cause: Cause, keepWords: Bool, now: Date) -> [Effect] {
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
  mutating func expiry(from now: Date, floor: TimeInterval = 0) -> [Effect] {
    guard windowMinutes > Self.untilStopped, let gen = state.generation else {
      windowUntil = nil
      return []
    }
    let until = now.addingTimeInterval(max(TimeInterval(windowMinutes) * Self.secondsPerMinute, floor))
    windowUntil = until
    return [.scheduleExpiry(until, gen)]
  }

  /// The record for the state as it stands, one sequence number on, with the
  /// mic live exactly when the state says the window is open.
  mutating func publish(now: Date) -> Effect {
    publish(now: now, micLive: state.isOpen)
  }

  /// The record for the state as it stands, one sequence number on.
  mutating func publish(now: Date, micLive: Bool) -> Effect {
    sequence += 1
    return .publish(record(sequence: sequence, now: now, micLive: micLive))
  }

  /// The state as a record, under the given sequence number.
  func record(sequence: UInt64, now: Date, micLive: Bool) -> ListeningState {
    ListeningState(
      launchID: launchID,
      sequence: sequence,
      window: state.window,
      idle: idle,
      micLive: micLive,
      windowUntil: windowUntil,
      utterance: state.utterance,
      reason: publishedReason,
      writtenAt: now
    )
  }
}
