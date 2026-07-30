/// Routes raw trigger-key events for **two** bound modifiers into a single
/// `DictationKeyGate`, reporting which `DictationMode` started the session.
///
/// Drives the two lone-modifier triggers (`DictationTriggerPair`) — a *raw* key
/// and a *cleaned* key — over one shared `DictationKeyGate`, so only one
/// dictation runs at a time no matter which key fires. It owns three decisions
/// the app's event-tap shim would otherwise carry untested:
///
/// - **Edge dedup**, per key. `flagsChanged` deliveries re-report each key's
///   flag bit whether or not it changed, so the router tracks both keys'
///   physical state and only a genuine down/up *edge* reaches the gate.
/// - **Ownership.** The first key to open the idle gate becomes its `owner` for
///   the life of that session; the *other* key's flag changes are ignored until
///   the gate returns to idle, so pressing the second trigger mid-dictation
///   can't hijack or double-fire the run. Ownership clears whenever the gate
///   goes idle (`postUpdate`).
/// - **Relevance.** Only the two bound keycodes' flag changes drive the
///   modifier; a `keyDown` for any *other* key marks a combo, and neither
///   trigger's own keycode counts as a combo.
///
/// Like the gate, the router reads no clock — callers pass monotonic timestamps
/// — so every decision is deterministic and unit-testable. The app-side
/// `DictationKeyTap` reduces each `CGEvent` to an `Event` and forwards it here.
public struct DualTriggerRouter: Sendable {
  /// A keyboard event reduced to exactly what the routing decision needs, so
  /// the router never touches `CGEvent`/`CGEventFlags` types. `flagsChanged`
  /// carries *both* triggers' device-dependent flag bits (see
  /// `TriggerKey.deviceModifierMask`); the router picks the one matching the
  /// event's keycode.
  public enum Event: Sendable, Equatable {
    case flagsChanged(keyCode: Int, rawFlagIsOn: Bool, cleanedFlagIsOn: Bool)
    case keyDown(keyCode: Int)
  }

  /// The gate's decision plus which mode owns it. `mode` is non-nil **only**
  /// when `action == .start`, naming the key that opened the session so the host
  /// can paste the matching (raw vs cleaned) transcript; every other action
  /// carries `nil`.
  public struct Outcome: Sendable, Equatable {
    public let action: DictationKeyGate.Action
    public let mode: DictationMode?
  }

  /// The verbatim trigger's virtual keycode. Internal (not public): only the
  /// engine and tests read the property — the app passes it in via `init`/
  /// `rebind` — so a public getter would trip periphery's redundant-public
  /// check. `cleanedKeyCode` stays public because the UITEST harness reads it.
  private(set) var rawKeyCode: Int
  /// The cleanup-rewrite trigger's virtual keycode.
  public private(set) var cleanedKeyCode: Int

  private var gate: DictationKeyGate
  /// Each key's current physical state, so repeated `flagsChanged` deliveries
  /// with an unchanged bit don't re-fire the gate.
  private var rawDown = false
  private var cleanedDown = false
  /// Which key currently owns the live gate, or nil when idle. Set when a key
  /// opens the idle gate; cleared by `postUpdate` once the gate returns to idle.
  private var owner: DictationMode?

  public init(rawKeyCode: Int, cleanedKeyCode: Int, holdThreshold: Duration = .seconds(1)) {
    self.rawKeyCode = rawKeyCode
    self.cleanedKeyCode = cleanedKeyCode
    self.gate = DictationKeyGate(holdThreshold: holdThreshold)
  }

  /// Feeds one event through the relevance/edge/ownership filters into the gate
  /// and returns its decision plus the owning mode on a start.
  public mutating func handle(_ event: Event, at now: Duration) -> Outcome {
    switch event {
    case .flagsChanged(let keyCode, let rawFlagIsOn, let cleanedFlagIsOn):
      let role: DictationMode
      let bit: Bool
      if keyCode == rawKeyCode {
        role = .raw
        bit = rawFlagIsOn
      } else if keyCode == cleanedKeyCode {
        role = .cleaned
        bit = cleanedFlagIsOn
      } else {
        return Outcome(action: .none, mode: nil)
      }
      // Edge dedup against this role's tracked physical state.
      let wasDown = (role == .raw) ? rawDown : cleanedDown
      guard bit != wasDown else { return Outcome(action: .none, mode: nil) }
      setDown(role, bit)
      return bit ? handleDown(role, at: now) : handleUp(role, at: now)
    case .keyDown(let keyCode):
      // A trigger's own keyDown isn't a combo; any other key is.
      if keyCode == rawKeyCode || keyCode == cleanedKeyCode {
        return Outcome(action: .none, mode: nil)
      }
      let action = gate.otherKeyDown()
      postUpdate()
      return Outcome(action: action, mode: nil)
    }
  }

  /// A down *edge* for `role`. Opens the idle gate (claiming ownership and
  /// reporting the mode on a start), passes through when `role` already owns the
  /// gate, and is ignored when the *other* key holds a live session.
  private mutating func handleDown(_ role: DictationMode, at now: Duration) -> Outcome {
    if gate.isIdle {
      owner = role
      let action = gate.modifierDown(at: now)
      postUpdate()
      return Outcome(action: action, mode: action == .start ? role : nil)
    }
    if owner == role {
      let action = gate.modifierDown(at: now)
      postUpdate()
      return Outcome(action: action, mode: nil)
    }
    // The other trigger while a session is active — ignored (no chord across
    // the two keys), though its physical down-state is still tracked above.
    return Outcome(action: .none, mode: nil)
  }

  /// An up *edge* for `role`. Only the owning key can release the gate; the
  /// other key's release (tracked, but never having driven the gate) is inert.
  private mutating func handleUp(_ role: DictationMode, at now: Duration) -> Outcome {
    guard owner == role else { return Outcome(action: .none, mode: nil) }
    let action = gate.modifierUp(at: now)
    postUpdate()
    return Outcome(action: action, mode: nil)
  }

  private mutating func setDown(_ role: DictationMode, _ isDown: Bool) {
    switch role {
    case .raw: rawDown = isDown
    case .cleaned: cleanedDown = isDown
    }
  }

  /// Clears ownership whenever the gate returns to idle, so the next key to
  /// press opens a fresh session (and can be a different mode).
  private mutating func postUpdate() {
    if gate.isIdle { owner = nil }
  }

  /// Rebinds both triggers and resets: events already tracked belong to the old
  /// keys, whose up-events can no longer match. Returns whether the reset
  /// discarded a live recording (see `reset()`).
  @discardableResult
  public mutating func rebind(rawKeyCode: Int, cleanedKeyCode: Int) -> Bool {
    self.rawKeyCode = rawKeyCode
    self.cleanedKeyCode = cleanedKeyCode
    return reset()
  }

  /// Clears the gate (and both physical-state trackers plus ownership) because
  /// the events it was tracking can no longer be trusted — a binding changed, or
  /// the host's event tap was disabled and events were dropped. Returns true
  /// when the reset discarded a live gate state (armed or latched): no future
  /// key event can end that dictation, so the caller must cancel the recording
  /// upstream — otherwise the session sits in `.recording` until the
  /// auto-release cap pastes an unprompted transcript.
  @discardableResult
  public mutating func reset() -> Bool {
    let discardedRecording = !gate.isIdle
    gate.reset()
    rawDown = false
    cleanedDown = false
    owner = nil
    return discardedRecording
  }
}
