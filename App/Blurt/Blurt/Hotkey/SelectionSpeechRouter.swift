import AppKit
import BlurtEngine

/// Sits between the trigger key and the dictation session, and turns a press
/// over selected text into "read it aloud" when the experimental switch is on
/// (`SelectionSpeechStore`), or, holding the key with asking on
/// (`SelectionAskStore`), into "answer what I'm saying about it". When the
/// switch is off, every command goes straight to `DictationSession.submit`.
///
/// The decisions are the engine's `SelectionSpeechRouting`. This class carries
/// out the actions it returns: the selection read, the hold timer, the speech
/// task, and the gate resets.
///
/// The cost: while the switch is on, a dictation press starts one AX read later.
/// That's a few milliseconds in a native app, but can be tens to hundreds in an
/// Electron app, and up to the AX timeout for each round trip against a hung
/// one. Recording starts at the press, so a slow read clips the first words.
/// An ask doesn't pay it: its recording starts at the hold, after the start
/// chime the user waits for.
final class SelectionSpeechRouter {
  private static let logger = HostIdentity.current.logger("SelectionSpeech")

  private let session: DictationSession
  private let speaker = SelectionSpeaker()
  private var routing = SelectionSpeechRouting()
  private var speech: Task<Void, Never>?
  /// The pending `holdElapsed`, restarted by each press that may ask.
  private var holdTimer: Task<Void, Never>?
  /// `DictationKeyTap.syncAfterTerminalPhase`: a dictation ended without a key event.
  var syncGateAfterSession: () -> Void = {}
  /// `DictationKeyTap.resetGate`: a read ended without a key event.
  var resetGate: () -> Void = {}

  init(session: DictationSession) {
    self.session = session
  }

  func submit(_ command: DictationSession.Command) {
    perform(
      routing.submit(
        command, readAloudEnabled: SelectionSpeechStore().isEnabled, askEnabled: SelectionAskStore().isEnabled))
  }

  /// `DictationKeyTap`'s latch: the press was a tap.
  func keyLatched() {
    perform(routing.keyLatched())
  }

  func sessionReachedTerminalPhase(_ phase: PipelinePhase) {
    perform(routing.sessionReachedTerminalPhase(phase))
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
      case .startHoldTimer: startHoldTimer()
      case .speak(let text):
        // Read per press, like the switch itself, so a Settings change applies
        // to the next read.
        let style = ReadAloudStyleStore().style
        run { [speaker] in try await speaker.speak(text, style: style) }
      case .answer(let request, let selection):
        let style = ReadAloudStyleStore().style
        run { [speaker] in try await speaker.answer(request, about: selection, style: style) }
      case .stopSpeech:
        speech?.cancel()
        speech = nil
      case .syncGateAfterSession: syncGateAfterSession()
      case .resetGate: resetGate()
      }
    }
  }

  /// One timer at a time: a newer press cancels the older one's, so a timer
  /// left over from a quick tap can't mark the next press as a hold.
  private func startHoldTimer() {
    holdTimer?.cancel()
    holdTimer = Task { [weak self] in
      try? await Task.sleep(for: SelectionSpeechRouting.askHoldDelay)
      guard !Task.isCancelled, let self else { return }
      self.holdTimer = nil
      self.perform(self.routing.holdElapsed())
    }
  }

  /// Runs one read or answer as the current speech task.
  private func run(_ work: @escaping @Sendable () async throws -> Void) {
    speech = Task { [weak self] in
      do {
        try await work()
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
