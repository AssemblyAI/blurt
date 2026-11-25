/// Writes what spoken instructions describe ("ok, a Slack reply to Dan: we
/// should have a feature to just speak instructions, keep it casual"), for the
/// Compose From Instructions key (`SelectionSpeechRouting`). Public so a host
/// can stand in its own (the engine's tests and the app's UI tests do).
public protocol MessageComposing: Sendable {
  /// The text `instructions` describe, ready to paste into `app` — the
  /// frontmost app's name, nil when it isn't known.
  func compose(_ instructions: String, for app: String?) async throws -> String
}
