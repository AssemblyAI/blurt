/// Routes raw trigger-key events into `DictationKeyGate` and owns the three
/// decisions that would otherwise sit untested in the app's event-tap shim:
///
/// - **Edge dedup.** `flagsChanged` deliveries re-report the bound key's flag
///   bit whether or not it changed, so the router tracks the modifier's current
///   physical state and only a genuine down/up *edge* reaches the gate —
///   repeated same-state deliveries must not double-fire a dictation.
/// - **Relevance.** Only the bound keycode's flag changes drive the modifier;
///   a `keyDown` for any *other* key marks a combo (e.g. ⌘C over the held
///   trigger), and the trigger's own keycode never counts as a combo.
/// - **Dropped-event recovery.** After the host's tap is disabled and re-enabled,
///   whether the gate's state survives depends on the trigger still being held —
///   see `recoverFromDroppedEvents(triggerStillHeld:)`.
///
/// Like the gate, the router reads no clock — callers pass monotonic timestamps
/// — so every decision is deterministic and unit-testable. The app-side
/// `DictationKeyTap` reduces each `CGEvent` to an `Event` and forwards it here.
public struct DictationKeyRouter: Sendable {
  /// A keyboard event reduced to exactly what the routing decision needs, so
  /// the router never touches `CGEvent`/`CGEventFlags` types.
  public enum Event: Sendable, Equatable {
    /// A `flagsChanged` delivery: the keycode it reports and whether the bound
    /// trigger's device-dependent flag bit is set in the event's flags (see
    /// `TriggerKey.deviceModifierMask`).
    case flagsChanged(keyCode: Int, triggerFlagIsOn: Bool)
    /// A `keyDown` for `keyCode`.
    case keyDown(keyCode: Int)
  }

  /// The virtual keycode of the bound trigger modifier (`TriggerKey.keyCode`).
  public private(set) var triggerKeyCode: Int

  private var gate: DictationKeyGate
  /// The bound modifier's current physical state, so repeated `flagsChanged`
  /// deliveries with an unchanged bit don't re-fire the gate.
  private var modifierIsDown = false

  public init(triggerKeyCode: Int, holdThreshold: Duration = .seconds(1)) {
    self.triggerKeyCode = triggerKeyCode
    self.gate = DictationKeyGate(holdThreshold: holdThreshold)
  }

  /// Feeds one event through the relevance/edge filters into the gate and
  /// returns its decision.
  public mutating func handle(_ event: Event, at now: Duration) -> DictationKeyGate.Action {
    switch event {
    case .flagsChanged(let keyCode, let triggerFlagIsOn):
      guard keyCode == triggerKeyCode else { return .none }
      if triggerFlagIsOn, !modifierIsDown {
        modifierIsDown = true
        return gate.modifierDown(at: now)
      }
      if !triggerFlagIsOn, modifierIsDown {
        modifierIsDown = false
        return gate.modifierUp(at: now)
      }
      return .none
    case .keyDown(let keyCode):
      return keyCode == triggerKeyCode ? .none : gate.otherKeyDown()
    }
  }

  /// Rebinds the trigger and resets: events already tracked belong to the old
  /// key, whose up-event can no longer match. Returns whether the reset
  /// discarded a live recording (see `reset()`).
  @discardableResult
  public mutating func rebind(triggerKeyCode: Int) -> Bool {
    self.triggerKeyCode = triggerKeyCode
    return reset()
  }

  /// Recovery after the host's event tap was disabled (by timeout, or by user input
  /// while it was down) and re-enabled: events may have been dropped, so the gate's
  /// state may no longer match the keyboard.
  ///
  /// `triggerStillHeld` is the caller's read of whether the trigger modifier is
  /// physically down *right now* — `CGEventSource.flagsState` on the app side, the
  /// one CoreGraphics-typed input, which is why it's passed in rather than read
  /// here. If it is, nothing that matters was lost: the key-up is still coming and
  /// the gate is coherent, so the state is kept — resetting would discard speech the
  /// user is mid-sentence on. If it isn't, the trigger's key-up may have been among
  /// the dropped events, so the gate is reset.
  ///
  /// Returns whether that reset discarded a live recording the caller must cancel
  /// upstream, matching `reset()` and `rebind(triggerKeyCode:)`. This lived in the
  /// shell as a bare `if`, where nothing could test it — the app target has no test
  /// target and a `CGEventTap` can't be driven from XCUITest — while carrying the
  /// worst failure of the three decisions here: a session left in `.recording` with
  /// no key event able to end it, until the auto-release cap pastes an unprompted
  /// transcript.
  @discardableResult
  public mutating func recoverFromDroppedEvents(triggerStillHeld: Bool) -> Bool {
    guard !triggerStillHeld else { return false }
    return reset()
  }

  /// Clears the gate (and the modifier-down tracker) because the events it was
  /// tracking can no longer be trusted — the binding changed, or the host's
  /// event tap was disabled and events were dropped. Returns true when the
  /// reset discarded a live gate state (armed or latched): no future key event
  /// can end that dictation, so the caller must cancel the recording upstream
  /// — otherwise the session sits in `.recording` until the auto-release cap
  /// pastes an unprompted transcript.
  @discardableResult
  public mutating func reset() -> Bool {
    let discardedRecording = !gate.isIdle
    gate.reset()
    modifierIsDown = false
    return discardedRecording
  }
}
