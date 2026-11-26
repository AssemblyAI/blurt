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

extension TriggerKeyAction {
  /// Whether a press records — cued on the capture's edges, so its cue voice
  /// is reloaded with dictation's (`CueReprimeSchedule.Reloads.dictation`).
  /// Every action but a read records: an ask, a rewrite, a compose and a
  /// command each record the instruction they act on.
  public var records: Bool { self != .readAloud }

  /// Whether a press speaks — cued around a read, so its cue voice is reloaded
  /// with read-aloud's (`CueReprimeSchedule.Reloads.readAloud`). An ask both
  /// records and speaks.
  public var speaks: Bool { self == .readAloud || self == .ask }

  /// The cue setting a key with no voice of its own follows: a read key sounds
  /// like a read and a command key like a command, and any other key —
  /// dictate, ask, rewrite, compose, each a recording — like a dictation.
  public var cue: SoundPackStore.Cue {
    switch self {
    case .readAloud:
      .readAloud

    case .command:
      .command

    case .off, .dictate, .ask, .rewrite, .compose:
      .dictation
    }
  }
}
