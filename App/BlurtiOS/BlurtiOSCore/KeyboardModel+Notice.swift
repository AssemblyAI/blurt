import BlurtEngine
import Foundation

// MARK: - The one line of words under the mic

extension KeyboardModel {
  /// The status line, if any (`VoiceNotice`): what the keyboard knows — Full
  /// Access, the readiness record, the phase on screen, the error it holds,
  /// the press it has out — and what a tap does while the line shows.
  package var statusLine: VoiceNotice.Line? {
    // Read so the timed rows are evaluated again when the clock says so.
    _ = noticeTick
    return VoiceNotice.line(
      for: VoiceNotice.Input(
        hasFullAccess: hasFullAccess, state: noticeState, snapshot: snapshot, heldError: heldError,
        handshake: handshake.state.notice, now: now()))
  }

  /// The record the line reads. A preview sets `isListening` by hand with no
  /// record behind it (a preview): the line then reads
  /// the readiness it was given rather than a session that is off.
  private var noticeState: ListeningState? {
    if let listeningState { return listeningState }
    guard isListening else { return nil }
    return ListeningState(launchID: UUID(), sequence: 0, window: .open, micLive: true, writtenAt: now())
  }

  /// The line's timed rows are read again when they can change: every second
  /// through the last stretch of a recording (the countdown), and once a
  /// transcription has run past the line's patience.
  package func runNoticeClock(for current: PhaseSnapshot) {
    noticeClock?.cancel()
    noticeClock = nil
    switch current.state {
    case .recording:
      guard let since = current.recordingSince else { return }
      let countdownFrom = since.addingTimeInterval(SyncSTTLimits.autoReleaseSeconds - VoiceNotice.countdownWindow)
      noticeClock = Task { [weak self] in
        guard let self else { return }
        try? await Task.sleep(for: .seconds(max(0, countdownFrom.timeIntervalSince(now()))))
        while !Task.isCancelled, snapshot.state == .recording {
          noticeTick += 1
          try? await Task.sleep(for: .seconds(1))
        }
      }
    case .processing:
      let patience = current.at.addingTimeInterval(VoiceNotice.transcribingPatience)
      noticeClock = Task { [weak self] in
        guard let self else { return }
        try? await Task.sleep(for: .seconds(max(0, patience.timeIntervalSince(now()))))
        guard !Task.isCancelled else { return }
        noticeTick += 1
      }
    case .idle, .connecting, .pasted, .copied, .error:
      break
    }
  }
}

extension PressHandshake.State {
  /// The handshake as the line sees it: the state alone, no payloads.
  package var notice: VoiceNotice.Handshake {
    switch self {
    case .idle: .idle
    case .pressing: .pressing
    case .owned: .owned
    case .stopping: .stopping
    case .foreign: .foreign
    case .unready(let reason): .unready(reason)
    }
  }
}
