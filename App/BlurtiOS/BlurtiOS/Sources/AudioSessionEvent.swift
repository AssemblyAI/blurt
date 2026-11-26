/// What the system says about the audio session while a window is open, in
/// the order it happened. One reader: the window, which turns each into the
/// machine's event.
enum AudioSessionEvent: Sendable, Equatable {
  /// A call, Siri, an alarm: the session is taken.
  case interruptionBegan
  /// Given back; `shouldResume` is the system's own advice.
  case interruptionEnded(shouldResume: Bool)
  /// Media services were reset under the session: everything audio is gone.
  case mediaReset
}
