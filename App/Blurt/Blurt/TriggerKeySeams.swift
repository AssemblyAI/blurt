import BlurtEngine

/// Stand-ins for the trigger keys' own jobs — read-aloud's speaker and
/// selection read, Rewrite Selection's rewriter, Control Your Mac's planner
/// and performer — so a host can run them with no network, audio or
/// Accessibility (Blurt's UI tests).
struct TriggerKeySeams {
  let speaker: any ReadAloudSpeaker
  let readSelection: @Sendable () async -> String?
  let rewriter: any SelectionRewriting
  let planner: any VoiceCommandPlanning
  let performer: any VoiceCommandPerforming
}
