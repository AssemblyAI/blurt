/// How the dictation trigger key activates a recording. The default keeps one
/// key doing both jobs — a quick tap toggles recording on and off, a longer
/// hold is push-to-talk — and the other two narrow it to a single gesture for
/// users who keep triggering the one they didn't mean. The raw value is what
/// `TriggerActivationStore` persists, so it follows `DefaultsKey`'s rule:
/// rename a case freely, its raw value never.
public enum TriggerActivation: String, CaseIterable, Sendable {
  /// Tap to toggle *and* hold to talk — the shipped behavior, and the unset
  /// default (`fromPersisted`).
  case tapOrHold = "TapOrHold"
  /// Tap to toggle only: every release latches recording on, however long the
  /// key was held, and the next tap stops it.
  case tap = "Tap"
  /// Hold to talk only: recording runs exactly while the key is down, so a
  /// release always stops and nothing ever latches.
  case hold = "Hold"

  /// Decodes a persisted raw value, falling back to the shipped tap-or-hold
  /// behavior for unset ("") or unknown values. The single decode-with-default
  /// rule shared by `TriggerActivationStore` and the `@AppStorage` view that
  /// reads the raw slot directly (so it re-renders live on a Settings change).
  public static func fromPersisted(_ raw: String) -> TriggerActivation {
    TriggerActivation(rawValue: raw) ?? .tapOrHold
  }

  /// Menu-picker title, e.g. "Tap or hold".
  public var label: String {
    switch self {
    case .tapOrHold: return "Tap or hold"
    case .tap: return "Tap"
    case .hold: return "Hold"
    }
  }

  /// The Shortcut section's footer sentence: how to dictate under this mode.
  /// Lives here rather than at the SwiftUI call site so the wording stays
  /// beside the behavior it describes (and inside the tested target).
  public var guidance: String {
    switch self {
    case .tapOrHold:
      return "Tap to start and tap again to stop, or hold the key and release to dictate."
    case .tap:
      return "Tap to start and tap again to stop dictating."
    case .hold:
      return "Hold the key while you speak and release to stop dictating."
    }
  }

  /// Whether releasing the trigger latches the recording on (tap-to-toggle)
  /// rather than stopping it, given how long this press was held. Only presses
  /// that *started* the recording ask — a release over an already-latched
  /// recording always stops (see `DictationKeyGate.modifierUp`).
  func latchesOnRelease(heldFor held: Duration, holdThreshold: Duration) -> Bool {
    switch self {
    case .tapOrHold: return held < holdThreshold
    case .tap: return true
    case .hold: return false
    }
  }
}
