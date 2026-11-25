/// What a press of one trigger key does (`TriggerKeyBindings.action(for:)`).
public enum TriggerKeyAction: Sendable, Hashable {
  case off
  /// Dictates, with the style the key's choice names.
  case dictate
  /// Reads the selected text aloud (`SelectionSpeechRouting`).
  case readAloud
  /// Records a spoken request about the selected text and reads the answer aloud.
  case ask
  /// Records a spoken instruction ("make it more formal") and pastes the
  /// selected text, rewritten that way, over it.
  case rewrite
  /// Records spoken instructions for something to write ("a Slack reply to
  /// Dan saying we should…") and pastes what they describe at the cursor
  /// (`MessageComposer`). Needs no selection.
  case compose
  /// Records a spoken command ("open Slack and start a new message") and
  /// carries it out (`VoiceCommandPlanner`, `VoiceCommandPerforming`).
  case command
}
