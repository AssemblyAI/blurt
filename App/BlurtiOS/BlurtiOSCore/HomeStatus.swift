import BlurtEngine

/// What the home screen says: the session, on
/// or off, and one line about it, rather than every phase of every dictation
/// (the keyboard shows those where the user is typing). Plus whether setup is
/// complete. Pure, so the wording is tested and the view only lays it out.
package nonisolated struct HomeStatus: Equatable {
  /// The card's eyebrow: "Session on" or "Session off".
  package let label: String
  /// The listening window is open, so the Blurt keyboard can dictate.
  package let isOn: Bool
  /// The line under it: what to do now, and how long the session lasts.
  package let message: String
  /// A dictation that failed, said plainly; nil when nothing did.
  package let error: String?
  /// A key, the microphone and the keyboard, all in place.
  package let isSetUp: Bool

  package init(
    overlay: OverlayUIState, windowOpen: Bool, windowMinutes: Int, micDenied: Bool, hasKey: Bool, micGranted: Bool,
    keyboardSeen: Bool
  ) {
    isOn = windowOpen
    label = windowOpen ? "Session on" : "Session off"
    if micDenied {
      message = "Blurt needs microphone access to dictate. Turn it on in Settings."
    } else if windowOpen {
      message = "Use the Blurt keyboard's mic in any app. " + Self.endsAfter(minutes: windowMinutes)
    } else {
      message = "Start a session to dictate with the Blurt keyboard in any app."
    }
    if case .error(let text, _) = overlay { error = text } else { error = nil }
    isSetUp = hasKey && micGranted && keyboardSeen
  }

  /// How long an idle session stays on: "Ends after 15 idle minutes."; 0 is
  /// the window's "until you stop it".
  static func endsAfter(minutes: Int) -> String {
    switch minutes {
    case ...0: "Stays on until you end it."
    case 1: "Ends after 1 idle minute."
    default: "Ends after \(minutes) idle minutes."
    }
  }
}
