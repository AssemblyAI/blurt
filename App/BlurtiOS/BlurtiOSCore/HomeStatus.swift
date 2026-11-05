import BlurtEngine
import Foundation

/// What the home screen says: the session, on
/// or off, and one line about it, rather than every phase of every dictation
/// (the keyboard shows those where the user is typing). Plus whether setup is
/// complete. Pure, so the wording is tested and the view only lays it out.
///
/// The session is read off the window's own record (`ListeningState`): the
/// same record the keyboard decides on, so the card and the orb can't disagree
/// about whether a press records.
package nonisolated struct HomeStatus: Equatable {
  /// How long a failed dictation's sentence stays on the card. Any change of
  /// the window's state clears it sooner, so a headline about a failure never
  /// outlives the session it happened in (DESIGN.md).
  package static let errorDwell: TimeInterval = 3

  /// The session is on: the window is open, opening, or waiting out an interruption.
  package let isOn: Bool
  /// The card's eyebrow.
  package var label: String { isOn ? "Session on" : "Session off" }
  /// The line under it: what to do now, and how long the session lasts.
  package let message: String
  /// A dictation that failed, said plainly; nil when nothing did.
  package let error: String?
  /// A key, the microphone and the keyboard, all in place.
  package let isSetUp: Bool

  package init(
    state: ListeningState?, windowMinutes: Int, error: String?, micDenied: Bool, hasKey: Bool, micGranted: Bool,
    keyboardSeen: Bool
  ) {
    let window = state?.window ?? .closed
    isOn = [.opening, .open, .interrupted].contains(window)
    if micDenied {
      message = "Blurt needs microphone access to dictate. Turn it on in Settings."
    } else {
      message = Self.message(window: window, state: state, windowMinutes: windowMinutes)
    }
    self.error = error
    isSetUp = hasKey && micGranted && keyboardSeen
  }

  private static func message(window: ListeningState.Window, state: ListeningState?, windowMinutes: Int) -> String {
    switch window {
    case .closed, .closing:
      return "Start a session to dictate with the Blurt keyboard in any app."
    case .opening:
      return "Starting the session…"
    case .interrupted:
      return "The mic is paused: a call or another app has it. The session carries on when that ends."
    case .open:
      let lifetime = state?.windowUntil == nil ? "Stays on until you end it." : endsAfter(minutes: windowMinutes)
      return "Use the Blurt keyboard's mic in any app. \(lifetime) \(micLine(idle: state?.idle ?? .held))"
    }
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

  /// What the orange dot does between dictations, by the idle mode in use.
  static func micLine(idle: ListeningState.Idle) -> String {
    switch idle {
    case .held: "The mic stays open while the session is on."
    case .pip: "The mic opens only while you dictate."
    }
  }
}
