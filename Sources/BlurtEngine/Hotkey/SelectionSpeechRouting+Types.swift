// `SelectionSpeechRouting`'s vocabulary: the actions it returns, and the
// state it keeps between them. Apart from the decisions themselves
// (`SelectionSpeechRouting.swift`) only to keep that file readable; nothing
// outside the routing uses the state types.

extension SelectionSpeechRouting {
  /// How long a read or ask key must stay down, in a mode that holds, before
  /// the press counts. Well under the gate's 1 s tap/hold threshold, because an
  /// asker waits this long (plus the mic bring-up) for the start chime before
  /// speaking; a deliberate tap is over long before it.
  static let holdDelay = Duration.milliseconds(350)

  enum Action: Sendable, Equatable {
    case forward(DictationSession.Command)
    /// Start the Accessibility read. Its result comes back through `selectionResolved`.
    case readSelection
    /// Call `holdElapsed` after `holdDelay`, unless a newer press restarts it.
    case startHoldTimer
    case speak(String)
    /// Answer the spoken `request` about `selection`, aloud.
    case answer(request: String, selection: String)
    /// Rewrite `selection` as the spoken `request` asks, and paste it over the selection.
    case rewrite(request: String, selection: String)
    /// Write what the spoken `request` describes, and paste it at the cursor.
    case compose(request: String)
    case stopSpeech
    /// Carry out the spoken `command`.
    case runCommand(String)
    /// A command press proved itself: get the screen ready to read while the
    /// command is spoken (`VoiceCommandPerforming.commandStarting`).
    case prepareCommand
    /// A command's recording ended: read the screen while it transcribes, for
    /// `.runCommand` to plan with.
    case readScreen
    /// Abandon the job in flight — a rewrite or a composition before it
    /// pastes, a command before its next step.
    case stopJob
    /// A dictation ended without a key event: `DictationKeyTap.syncAfterTerminalPhase`.
    case syncGateAfterSession
    /// The gate is latched or armed by a key press that holds no recording: a read
    /// ending on its own, a press that only stopped something, a held ask let go
    /// before it asked. Clear the gate with no recording discarded.
    case resetGate
  }

  enum Intent: Sendable, Equatable {
    case read, ask, rewrite, compose, command

    /// The request a key's action makes; every non-request key reads.
    init(_ action: TriggerKeyAction) {
      switch action {
      case .ask: self = .ask
      case .rewrite: self = .rewrite
      case .compose: self = .compose
      case .command: self = .command
      case .readAloud, .dictate, .off: self = .read
      }
    }

    /// Whether the press records a spoken request (`.asking`) rather than reading.
    var records: Bool { self != .read }

    /// What dropping a press that reached `.asking` leaves to undo. A command
    /// prepared its screen there (`.prepareCommand`): its read is under way
    /// and, in a Chromium browser, its page tree switched on, so `.stopJob`
    /// stops one and undoes the other — whether it was dropped by a combo,
    /// nothing said, a press while it transcribed, or an Escape. Nothing for
    /// any other request, and nothing before `.asking`, which prepared nothing.
    var abandoned: [Action] { self == .command ? [.stopJob] : [] }
  }

  /// How a read or ask press proved itself: a tap (the gate latched), or a
  /// hold (still down at `holdDelay`).
  enum Trigger: Sendable, Equatable {
    case tap, hold
  }

  enum Mode: Sendable, Equatable {
    case passthrough
    /// The selection read is in flight. `trigger`: how the press already
    /// proved itself, if it has. `ended`: the key let go or a combo cancelled
    /// it; the gate is idle.
    case deciding(Intent, trigger: Trigger?, ended: Bool)
    /// A selection is in hand, and the key is down but hasn't proved itself yet.
    case selected(Intent, String)
    /// Recording the spoken request about the selection (an ask's question,
    /// or a rewrite's instruction: `intent`). Not `started` while
    /// an earlier dictation is still finishing: the hand-back press waits for
    /// it, since the session refuses a press until it is back at rest.
    /// `byHold`: the key is held for the request, so letting it go — even
    /// before the gate's own hold threshold — ends it; a tapped request runs
    /// until the next tap, like a dictation.
    case asking(Intent, String, started: Bool, byHold: Bool)
    /// The request was let go of and is being transcribed (or, not `started`,
    /// was let go of before the mic ever opened).
    case transcribing(Intent, String, started: Bool)
    case speaking
    /// A rewrite, a composition or a command is under way: the router's one job. Like
    /// `.speaking`, the gate is free under it, and any press abandons it.
    case working
  }
}
