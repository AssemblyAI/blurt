import Foundation

/// Whether Blurt turns a session on by itself as it comes to the front. On by
/// default, so the keyboard works in place without a trip to the switch — but
/// a session the user turned off stays off, across launches, until they turn
/// one on again (the switch, or the keyboard's mic, which asks for one). The
/// window ending on its own (its time ran out, a call took the microphone) is
/// not the user turning it off.
package nonisolated enum SessionAutoStart {
  /// Set while the user's last word on the session was the switch turning it off.
  package static let turnedOffKey = "SessionTurnedOff"

  /// Only when nothing would ask the user anything — a key saved, consent
  /// given, the microphone already allowed — so it never puts up a sheet or a
  /// permission prompt unasked, and never against the switch.
  package static func shouldStart(
    windowOpen: Bool, hasKey: Bool, consented: Bool, micGranted: Bool, turnedOff: Bool
  ) -> Bool {
    !windowOpen && hasKey && consented && micGranted && !turnedOff
  }

  package static func isTurnedOff(in defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: turnedOffKey)
  }

  /// The user turned the session off (true) or asked for one (false).
  package static func setTurnedOff(_ turnedOff: Bool, in defaults: UserDefaults = .standard) {
    defaults.set(turnedOff, forKey: turnedOffKey)
  }
}
