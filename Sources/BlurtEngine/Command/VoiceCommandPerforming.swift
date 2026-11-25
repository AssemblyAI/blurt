/// Carries out the steps a command planned, other than `type` (which pastes
/// through the session's injector). Public so a host can stand in its own
/// (the engine's tests do).
public protocol VoiceCommandPerforming: Sendable {
  /// The beat between two steps, so the app has handled one before the next
  /// lands (⌘K's palette open before its search is typed). None after the last.
  var settle: Duration { get }

  /// What's on screen when the command was spoken, for the planner: the app
  /// in front ("new tab" means that app's) and what its window offers to act
  /// on. The elements' numbers stay this performer's until the next snapshot.
  func screenContext() async -> ScreenContext
  /// Carries `step` out, answering how — "AXPress, then click", "key code 40"
  /// — for the developer-mode command log, or nil when there's nothing to say.
  func perform(_ step: VoiceCommandStep) async throws -> String?
  /// A command press proved itself and the command is about to be spoken:
  /// time the performer can spend getting the screen ready to read (a
  /// Chromium browser takes about two seconds to build its page tree).
  func commandStarting() async
  /// The command ran, failed, or was abandoned: undo what
  /// `commandStarting` changed.
  func commandEnded() async
}
