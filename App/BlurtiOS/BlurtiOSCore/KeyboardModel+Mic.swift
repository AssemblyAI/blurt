import BlurtEngine
import Foundation
import UIKit

// MARK: - The mic key: the handshake, driven by the finger

extension KeyboardModel {
  /// Whether a tap on the orb can do anything but open the app.
  package var isReady: Bool { hasFullAccess && isListening }

  /// Why a press would not record now, as the record says it; `sessionOff`
  /// with no record, or with no Full Access to read one.
  package var readinessReason: FailureReason? {
    guard hasFullAccess else { return .sessionOff }
    guard !isListening else { return nil }
    return listeningState?.notReady(now: now()) ?? .sessionOff
  }

  /// What the voice control shows: the phase the app published — or, from
  /// the press going out until the app answers it, the mic coming up.
  package var voiceState: VoiceState {
    if showsConnecting, snapshot.state.isSettled { return VoiceState(phase: .connecting, isReady: isReady) }
    return VoiceState(snapshot: snapshot, isReady: isReady)
  }

  /// Finger down on the orb. The readiness record is read now — not a beat
  /// ago — and the status line's own routing comes first: a line that says
  /// the tap opens Blurt makes it so, whatever the record says, so the words
  /// and the tap can never disagree. Then the handshake decides: a press, a
  /// latch over a dictation already running, a buzz over words being made.
  package func micDown() {
    readListeningState()
    let line = statusLine
    heldError = nil
    touchDown = elapsed
    armedFromIdle = false
    let ready: Bool
    let reason: FailureReason?
    switch line?.tapOpens {
    case .hop(let hop):
      ready = false
      reason = hop ?? readinessReason
    case .setup:
      ready = false
      reason = .sessionOff
    case .press, .buzz, nil:
      ready = isReady
      reason = readinessReason
    }
    KeyboardLog.readiness(sequence: listeningState?.sequence, ready: ready, reason: reason)
    let event = PressHandshake.Event.micDown(
      ready: ready, reason: reason, phase: snapshot.state, inFlight: snapshot.dictation)
    perform(handshake.handle(event, now: now()))
  }

  /// Finger up. The gate is told too, so it stays in step, but the decision
  /// — a tap that latched, a hold that stops, a lift that opens the app —
  /// is the handshake's, from the stamps the gate got.
  package func micUp() {
    let lift = elapsed
    let held = touchDown.map { lift - $0 } ?? .zero
    _ = gate.modifierUp(at: lift)
    let fromIdle = armedFromIdle
    armedFromIdle = false
    touchDown = nil
    perform(handshake.handle(.micUp(armedFromIdle: fromIdle, heldFor: held / .seconds(1)), now: now()))
  }

  /// The × key: the dictation ends and its words are thrown away.
  package func cancel() {
    perform(handshake.handle(.cancelTapped, now: now()))
  }

  /// A swipe that began on the orb (the panel's carousel) after its press
  /// went out: undo exactly what that press did, while nothing has been
  /// recorded — the press unanswered, or its dictation still coming up. Over
  /// a recording or words being made the swipe undoes nothing: the press
  /// latched onto it at most, and a cancel would land on the words — the
  /// picture can say recording for a moment after this keyboard released
  /// it, and a press the orb ignored started nothing.
  package func undoPress() {
    switch snapshot.state {
    case .recording, .processing: return
    case .idle, .connecting, .pasted, .copied, .error: perform(handshake.undoBeforeRecording(now: now()))
    }
  }

  /// The term field takes the mic's row, so a dictation in flight is closed
  /// first — nothing runs on with no key to stop it. `keepWords`: a release,
  /// the words still land; else a cancel. A press unanswered is taken back
  /// either way, since nothing has been recorded; a stop already out needs
  /// no second.
  package func endDictation(keepWords: Bool) {
    switch handshake.state {
    case .idle, .unready, .stopping: return
    case .pressing: perform([keepWords ? .sendRelease(dictation: nil) : .sendCancel(dictation: nil)])
    case .owned(let dictation, _), .foreign(let dictation, _):
      perform([keepWords ? .sendRelease(dictation: dictation) : .sendCancel(dictation: dictation)])
    }
  }
}
