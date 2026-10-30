/// Routes raw trigger-key events into `DictationKeyGate` and owns the three
/// decisions that would otherwise sit untested in the app's event-tap shim:
///
/// - **Edge dedup.** `flagsChanged` deliveries re-report the bound key's flag
///   bit whether or not it changed, so the router tracks the modifier's current
///   physical state and only a genuine down/up *edge* reaches the gate —
///   repeated same-state deliveries must not double-fire a dictation.
/// - **Relevance.** Only the bound keycodes' flag changes drive the modifier;
///   a `keyDown` for any *other* key marks a combo (e.g. ⌘C over the held
///   trigger), and a trigger's own keycode never counts as a combo. With more
///   than one trigger bound, the one whose press left the gate idle owns it
///   (`activeKeyCode`) until the gate is idle and that key is up again; the
///   others are ignored meanwhile, so two triggers never interleave.
/// - **Dropped-event recovery.** After the host's tap is disabled and re-enabled,
///   whether the gate's state survives depends on the trigger still being held —
///   see `recoverFromDroppedEvents(heldFlags:)`.
///
/// Like the gate, the router reads no clock — callers pass monotonic timestamps
/// — so every decision is deterministic and unit-testable. The app-side
/// `DictationKeyTap` reduces each `CGEvent` to an `Event` and forwards it here.
public struct DictationKeyRouter: Sendable {
  /// A keyboard event reduced to exactly what the routing decision needs, so
  /// the router never touches `CGEvent`/`CGEventFlags` types.
  public enum Event: Sendable, Equatable {
    /// A `flagsChanged` delivery: the keycode it reports and whether that
    /// key's device-dependent flag bit is set in the event's flags (see
    /// `TriggerKey.deviceModifierMask`).
    case flagsChanged(keyCode: Int, triggerFlagIsOn: Bool)
    /// A `keyDown` for `keyCode`.
    case keyDown(keyCode: Int)
    /// A mouse button went down. A modifier held through a click is a
    /// modifier-click (⌘-click a link, ⌥-click in Finder), not a lone press, so
    /// it cancels the press exactly as another key would.
    case pointerDown

    /// A `flagsChanged` delivery from its keycode and the event's raw
    /// `CGEventFlags`: down when the flags hold *that* key's device bit — so
    /// every trigger key reads correctly, not only the bound one.
    public static func fromFlags(keyCode: Int, rawFlags: UInt64) -> Event {
      let isOn = TriggerKey(rawValue: keyCode).map { rawFlags & $0.deviceModifierMask != 0 } ?? false
      return .flagsChanged(keyCode: keyCode, triggerFlagIsOn: isOn)
    }
  }

  /// Each watched trigger's virtual keycode (`TriggerKey.keyCode`) and the
  /// activation mode its presses resolve under.
  private(set) var activations: [Int: TriggerActivation]

  /// The trigger that owns the gate — the one whose press started the current
  /// dictation — or nil while the gate is idle and no trigger is held. The host
  /// reads it on `.start` to know which key fired.
  public private(set) var activeKeyCode: Int?

  private var gate: DictationKeyGate
  /// The active modifier's current physical state, so repeated `flagsChanged`
  /// deliveries with an unchanged bit don't re-fire the gate.
  private var modifierIsDown = false

  /// Each key with its own mode (keycode → activation).
  public init(activations: [Int: TriggerActivation], holdThreshold: Duration = .seconds(1)) {
    self.activations = activations
    self.gate = DictationKeyGate(holdThreshold: holdThreshold, activation: activations.values.first ?? .tapOrHold)
  }

  /// Feeds one event through the relevance/edge filters into the gate and
  /// returns its decision.
  public mutating func handle(_ event: Event, at now: Duration) -> DictationKeyGate.Action {
    switch event {
    case .flagsChanged(let keyCode, let triggerFlagIsOn):
      guard activations[keyCode] != nil, (activeKeyCode ?? keyCode) == keyCode else { return .none }
      if triggerFlagIsOn, !modifierIsDown {
        modifierIsDown = true
        activeKeyCode = keyCode
        // A press from idle resolves under its own key's mode. The gate's mode
        // is `let` (its determinism contract), so a different one is a fresh gate;
        // an idle gate holds nothing to lose.
        if gate.isIdle, let activation = activations[keyCode], activation != gate.activation {
          gate = DictationKeyGate(holdThreshold: gate.holdThreshold, activation: activation)
        }
        return gate.modifierDown(at: now)
      }
      if !triggerFlagIsOn, modifierIsDown {
        modifierIsDown = false
        let action = gate.modifierUp(at: now)
        if gate.isIdle { activeKeyCode = nil }
        return action
      }
      return .none
    case .keyDown(let keyCode):
      return activations[keyCode] != nil ? .none : gate.otherKeyDown()
    case .pointerDown:
      return gate.otherKeyDown()
    }
  }

  /// Rebinds the triggers — which keys, and each one's mode, the two halves of
  /// the binding Settings can change — and resets only when the change touches
  /// what the gate is tracking: the active key unbound (its up-event can no
  /// longer match) or its mode changed (it would resolve under the old one).
  /// Any other key's change keeps the state, so a recording latched while
  /// Settings is open survives it; that key's next press picks up its mode.
  /// Returns whether a reset discarded a live recording (see `reset()`).
  @discardableResult
  public mutating func rebind(activations: [Int: TriggerActivation]) -> Bool {
    self.activations = activations
    guard let activeKeyCode else { return false }
    // An unbound active key resets even with the gate idle (a combo cancelled
    // its press, the key still down): its up-event can no longer match, so it
    // would hold `activeKeyCode` and lock every other key out.
    guard let activation = activations[activeKeyCode] else { return reset() }
    guard !gate.isIdle, activation != gate.activation else { return false }
    return reset()
  }

  /// Recovery after the host's event tap was disabled (by timeout, or by user input
  /// while it was down) and re-enabled: events may have been dropped, so the gate's
  /// state may no longer match the keyboard.
  ///
  /// `heldFlags` is the caller's read of the modifier flags physically down *right
  /// now* — `CGEventSource.flagsState` on the app side, the one CoreGraphics-typed
  /// input, which is why it's passed in rather than read here. The router checks
  /// the *active* trigger's device bit in it, as `Event.fromFlags` does, so which
  /// key decides is settled here rather than in the shell. If it is held, nothing
  /// that matters was lost: the key-up is still coming and
  /// the gate is coherent, so the state is kept — resetting would discard speech the
  /// user is mid-sentence on. If it isn't, the trigger's key-up may have been among
  /// the dropped events, so the gate is reset.
  ///
  /// Returns whether that reset discarded a live recording the caller must cancel
  /// upstream, matching `reset()` and `rebind(activations:)`. This lived in the
  /// shell as a bare `if`, where nothing could test it — the app target has no test
  /// target and a `CGEventTap` can't be driven from XCUITest — while carrying the
  /// worst failure of the three decisions here: a session left in `.recording` with
  /// no key event able to end it, until the auto-release cap pastes an unprompted
  /// transcript.
  @discardableResult
  public mutating func recoverFromDroppedEvents(heldFlags: UInt64) -> Bool {
    let activeKey = activeKeyCode.flatMap(TriggerKey.init(rawValue:))
    guard activeKey.map({ heldFlags & $0.deviceModifierMask == 0 }) ?? true else { return false }
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
    activeKeyCode = nil
    return discardedRecording
  }
}
