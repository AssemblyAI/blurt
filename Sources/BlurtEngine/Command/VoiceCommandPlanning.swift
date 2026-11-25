/// Turns a spoken command ("open Slack and search for budget") into the steps
/// that carry it out, for the Control Your Mac key (`SelectionSpeechRouting`).
/// Public so a host can stand in its own (the engine's tests do).
public protocol VoiceCommandPlanning: Sendable {
  /// `context`: what was on screen when it was spoken (`ScreenContext`).
  /// `trace`: filled with what the model was sent and answered, for the
  /// developer-mode log — even when the plan then fails.
  func plan(_ command: String, context: ScreenContext, trace: PlanTrace) async throws -> [VoiceCommandStep]
}
