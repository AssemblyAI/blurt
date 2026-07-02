/// Pure state machine for a **single lone-modifier** dictation trigger that
/// supports tap-to-toggle and hold-to-talk.
///
/// Recording starts the instant the trigger modifier goes down; what *releasing*
/// it means is decided on key-up by how long it was held: a release at or past
/// `holdThreshold` is a hold (push-to-talk → stop), a shorter release is a tap
/// (latch recording on; the next tap stops it). A press combined with any other
/// key is a normal modifier shortcut (e.g. ⌘C), not dictation.
///
/// The gate reads no clock — callers pass monotonic timestamps as a `Duration`
/// from a fixed reference, so every decision is deterministic and unit-testable.
public struct DictationKeyGate: Sendable {
  public enum Action: Sendable, Equatable { case none, start, stop, cancel }

  /// A release held at least this long counts as a hold (push-to-talk stop);
  /// shorter is a tap. 1 s is a good default when one key does both jobs.
  public var holdThreshold: Duration

  private enum State: Sendable, Equatable {
    case idle
    /// Recording is active; we're deciding whether this press is a tap or a hold.
    /// `fromIdle` is true when the press started from idle (so a combo discards
    /// the fresh capture); false when it started from `latched` (a combo there is
    /// a real shortcut over an already-running toggle recording).
    case armed(downAt: Duration, fromIdle: Bool)
    /// Recording, toggled on by a tap; waiting for the next tap to stop.
    case latched
  }

  private var state: State = .idle

  /// Whether the gate holds no in-flight dictation (neither armed nor latched).
  /// The event tap's disabled-tap recovery reads this before `reset()` to know
  /// whether the reset is discarding a live recording that the caller must
  /// cancel upstream — otherwise the session would stay `.recording` with no
  /// key-up ever arriving.
  public var isIdle: Bool { state == .idle }

  public init(holdThreshold: Duration = .seconds(1)) {
    self.holdThreshold = holdThreshold
  }

  public mutating func modifierDown(at now: Duration) -> Action {
    switch state {
    case .idle:
      state = .armed(downAt: now, fromIdle: true)
      return .start
    case .latched:
      // Pressing again over a latched (toggle) recording: decide on key-up
      // whether it's a tap-to-stop or a hold.
      state = .armed(downAt: now, fromIdle: false)
      return .none
    case .armed:
      return .none
    }
  }

  public mutating func modifierUp(at now: Duration) -> Action {
    guard case .armed(let downAt, let fromIdle) = state else { return .none }
    // A short release from idle latches recording on (tap-to-toggle); every other
    // release — a held push-to-talk, or any release over a latched recording — stops.
    if fromIdle, now - downAt < holdThreshold {
      state = .latched
      return .none
    }
    state = .idle
    return .stop
  }

  public mutating func otherKeyDown() -> Action {
    switch state {
    case .armed(_, let fromIdle):
      if fromIdle {
        state = .idle
        return .cancel
      }
      state = .latched
      return .none
    case .idle, .latched:
      return .none
    }
  }

  /// Clears state to idle without emitting — used when the event tap is disabled
  /// (timeout / system-initiated) and intervening events may have been missed,
  /// so the held state is no longer trustworthy.
  public mutating func reset() {
    state = .idle
  }
}
