/// Rewrites a selection the way a spoken instruction asks ("make it more
/// formal"), for the Rewrite Selection key (`SelectionSpeechRouting`).
/// Public so a host can stand in its own (the engine's tests do; the app's UI
/// tests don't drive a rewrite).
public protocol SelectionRewriting: Sendable {
  func rewrite(_ selection: String, as request: String) async throws -> String
}
