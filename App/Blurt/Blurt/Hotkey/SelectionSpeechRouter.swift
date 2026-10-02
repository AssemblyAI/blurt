import AppKit
import BlurtEngine

/// Sits between the trigger key and the dictation session, and turns a press
/// over selected text into "read it aloud" when the experimental switch is on
/// (`SelectionSpeechStore`). When the switch is off, every command goes straight
/// to `DictationSession.submit`.
///
/// The decisions are the engine's `SelectionSpeechRouting`. This class carries
/// out the actions it returns: the selection read, the speech task, and the
/// gate resets.
///
/// The cost: while the switch is on, a dictation press starts one AX read later.
/// That's a few milliseconds in a native app, but can be tens to hundreds in an
/// Electron app, and up to the AX timeout for each round trip against a hung
/// one. Recording starts at the press, so a slow read clips the first words.
final class SelectionSpeechRouter {
  private static let logger = HostIdentity.current.logger("SelectionSpeech")

  private let session: DictationSession
  private let speaker = SelectionSpeaker()
  private var routing = SelectionSpeechRouting()
  private var speech: Task<Void, Never>?
  /// `DictationKeyTap.syncAfterTerminalPhase`: a dictation ended without a key event.
  var syncGateAfterSession: () -> Void = {}
  /// `DictationKeyTap.resetGate`: a read ended without a key event.
  var resetGate: () -> Void = {}

  init(session: DictationSession) {
    self.session = session
  }

  func submit(_ command: DictationSession.Command) {
    perform(routing.submit(command, readAloudEnabled: SelectionSpeechStore().isEnabled))
  }

  func sessionReachedTerminalPhase() {
    perform(routing.sessionReachedTerminalPhase())
  }

  private func perform(_ actions: [SelectionSpeechRouting.Action]) {
    for action in actions {
      switch action {
      case .forward(let command): session.submit(command)
      case .readSelection:
        Task { [weak self] in
          let selection = await SelectionSpeaker.focusedSelection()
          guard let self else { return }
          self.perform(self.routing.selectionResolved(selection))
        }
      case .speak(let text): speak(text)
      case .stopSpeech:
        speech?.cancel()
        speech = nil
      case .syncGateAfterSession: syncGateAfterSession()
      case .resetGate: resetGate()
      }
    }
  }

  private func speak(_ text: String) {
    let speaker = speaker
    // Read per press, like the switch itself, so a Settings change applies to
    // the next read.
    let style = ReadAloudWorkModeStore().style
    speech = Task { [weak self] in
      do {
        try await speaker.speak(text, style: style)
      } catch is CancellationError {
      } catch {
        Self.logger.error("read-aloud failed: \(error.localizedDescription, privacy: .public)")
        NSSound.beep()
      }
      // A read this router stopped was cancelled, and a newer one may already
      // be playing, so only a read that ended on its own reports back.
      guard !Task.isCancelled, let self else { return }
      self.speech = nil
      self.perform(self.routing.speechFinished())
    }
  }
}
