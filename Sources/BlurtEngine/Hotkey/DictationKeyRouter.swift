/// Routes raw trigger events into `DictationKeyGate` and owns the three
/// decisions that would otherwise sit untested in the app's event-tap shim:
///
/// - **Edge dedup.** `flagsChanged` deliveries re-report the bound key's flag
///   bit whether or not it changed, and a held non-modifier key can re-report
///   its down state (autorepeat), so the router tracks the trigger's current
///   physical state and only a genuine down/up *edge* reaches the gate —
///   repeated same-state deliveries must not double-fire a dictation.
/// - **Relevance.** Only events for the bound trigger drive the gate, and which
///   event family that is follows the binding: a modifier binding listens to
///   `flagsChanged`, a key binding to `keyDown`/`keyUp`, a mouse binding to
///   `mouseDown`/`mouseUp`. For a **modifier** binding, a `keyDown` for any
///   *other* key marks a combo (e.g. ⌘C over the held trigger) and cancels the
///   fresh capture; the trigger's own keycode never counts as a combo. For a
///   key or mouse binding there is no combo rule: a modifier+key press *is* a
///   shortcut the user meant, but F5+K and Mouse4+K name nothing to macOS, so
///   another key while the trigger is held is just typing — cancelling the
///   dictation on it would punish exactly the input dictation produces.
/// - **Dropped-event recovery.** After the host's tap is disabled and re-enabled,
///   whether the gate's state survives depends on the trigger still being held —
///   see `recoverFromDroppedEvents(triggerStillHeld:)`.
///
/// Like the gate, the router reads no clock — callers pass monotonic timestamps
/// — so every decision is deterministic and unit-testable. The app-side
/// `DictationKeyTap` reduces each `CGEvent` to an `Event` and forwards it here.
public struct DictationKeyRouter: Sendable {
  /// An input event reduced to exactly what the routing decision needs, so
  /// the router never touches `CGEvent`/`CGEventFlags` types.
  public enum Event: Sendable, Equatable {
    /// A `flagsChanged` delivery: the keycode it reports and whether the bound
    /// trigger's device-dependent flag bit is set in the event's flags (see
    /// `TriggerKey.deviceModifierMask`). Only meaningful under a modifier
    /// binding; the flag argument is ignored otherwise.
    case flagsChanged(keyCode: Int, triggerFlagIsOn: Bool)
    /// A non-autorepeat `keyDown` for `keyCode` (the host filters autorepeat
    /// deliveries out — see `DictationKeyTap.routerEvent` — and the edge dedup
    /// here backstops any that slip through).
    case keyDown(keyCode: Int)
    /// A `keyUp` for `keyCode`.
    case keyUp(keyCode: Int)
    /// An `otherMouseDown` for the given `CGEvent` button number.
    case mouseDown(button: Int)
    /// An `otherMouseUp` for the given `CGEvent` button number.
    case mouseUp(button: Int)
  }

  /// The bound trigger (`TriggerKeyStore.triggerBinding`).
  public private(set) var binding: TriggerBinding

  private var gate: DictationKeyGate
  /// The bound trigger's current physical state, so repeated same-state
  /// deliveries (an unchanged flag bit, an autorepeat keyDown) don't re-fire
  /// the gate.
  private var triggerIsDown = false

  public init(binding: TriggerBinding, holdThreshold: Duration = .seconds(1)) {
    self.binding = binding
    self.gate = DictationKeyGate(holdThreshold: holdThreshold)
  }

  /// Feeds one event through the relevance/edge filters into the gate and
  /// returns its decision.
  public mutating func handle(_ event: Event, at now: Duration) -> DictationKeyGate.Action {
    switch binding {
    case .modifier(let key):
      return handleForModifier(key, event, at: now)
    case .key(let code):
      return handleForKey(code, event, at: now)
    case .mouseButton(let button):
      return handleForMouseButton(button, event, at: now)
    }
  }

  private mutating func handleForModifier(
    _ key: TriggerKey, _ event: Event, at now: Duration
  ) -> DictationKeyGate.Action {
    switch event {
    case .flagsChanged(let keyCode, let triggerFlagIsOn):
      guard keyCode == key.keyCode else { return .none }
      return edge(isDown: triggerFlagIsOn, at: now)
    case .keyDown(let keyCode):
      // Another key over the held modifier is a combo (a real shortcut).
      return keyCode == key.keyCode ? .none : gate.otherKeyDown()
    case .keyUp, .mouseDown, .mouseUp:
      return .none
    }
  }

  private mutating func handleForKey(
    _ code: Int, _ event: Event, at now: Duration
  ) -> DictationKeyGate.Action {
    switch event {
    case .keyDown(let keyCode):
      return keyCode == code ? edge(isDown: true, at: now) : .none
    case .keyUp(let keyCode):
      return keyCode == code ? edge(isDown: false, at: now) : .none
    case .flagsChanged, .mouseDown, .mouseUp:
      return .none
    }
  }

  private mutating func handleForMouseButton(
    _ boundButton: Int, _ event: Event, at now: Duration
  ) -> DictationKeyGate.Action {
    switch event {
    case .mouseDown(let button):
      return button == boundButton ? edge(isDown: true, at: now) : .none
    case .mouseUp(let button):
      return button == boundButton ? edge(isDown: false, at: now) : .none
    case .flagsChanged, .keyDown, .keyUp:
      return .none
    }
  }

  /// The shared edge filter: only a genuine change of the trigger's physical
  /// state reaches the gate, whatever event family reported it.
  private mutating func edge(isDown: Bool, at now: Duration) -> DictationKeyGate.Action {
    if isDown, !triggerIsDown {
      triggerIsDown = true
      return gate.modifierDown(at: now)
    }
    if !isDown, triggerIsDown {
      triggerIsDown = false
      return gate.modifierUp(at: now)
    }
    return .none
  }

  /// Rebinds the trigger and resets: events already tracked belong to the old
  /// binding, whose up-event can no longer match. Returns whether the reset
  /// discarded a live recording (see `reset()`).
  @discardableResult
  public mutating func rebind(binding: TriggerBinding) -> Bool {
    self.binding = binding
    return reset()
  }

  /// Recovery after the host's event tap was disabled (by timeout, or by user input
  /// while it was down) and re-enabled: events may have been dropped, so the gate's
  /// state may no longer match the input device.
  ///
  /// `triggerStillHeld` is the caller's read of whether the trigger is physically
  /// down *right now* — `CGEventSource.flagsState`/`keyState`/`buttonState` on the
  /// app side, the one CoreGraphics-typed input, which is why it's passed in rather
  /// than read here. If it is, nothing that matters was lost: the up-event is still
  /// coming and the gate is coherent, so the state is kept — resetting would discard
  /// speech the user is mid-sentence on. If it isn't, the trigger's up-event may
  /// have been among the dropped events, so the gate is reset.
  ///
  /// Returns whether that reset discarded a live recording the caller must cancel
  /// upstream, matching `reset()` and `rebind(binding:)`. This lived in the
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

  /// Clears the gate (and the trigger-down tracker) because the events it was
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
    triggerIsDown = false
    return discardedRecording
  }
}
