import BlurtEngine
import Foundation
import UIKit

// MARK: - What comes back from the app: phase, results, haptics

extension KeyboardModel {
  package func phaseChanged() {
    guard let current = SharedStore.read(PhaseSnapshot.self, forKey: BlurtShared.Key.phase) else { return }
    apply(current.isStale(now: now()) ? .idle : current)
    // The result's own signal can be missed, or held while this process was
    // suspended: a phase that says the words are being made, or were, is
    // one more moment to look for them.
    if expectsResult { resultArrived() }
  }

  /// Words may be on their way to this keyboard: a dictation of its own is
  /// in flight or being stopped, or the app is transcribing one.
  package var expectsResult: Bool {
    handshake.isOwned || handshake.stopID != nil || snapshot.state == .processing
  }

  package func apply(_ current: PhaseSnapshot, haptics wantsHaptics: Bool = true) {
    // A notice the keyboard already let go of (its dwell ran out) is not
    // replayed by a second read of the same snapshot.
    if let dismissedNoticeAt, current.at == dismissedNoticeAt { return }
    let previous = snapshot.state
    // A dictation in flight belongs to an app that is there to run it: with
    // the app gone — its lease lapsed, or no record at all — the picture is
    // idle, not a mic nobody can stop. A record merely not ready (the window
    // closed or interrupted) is an app alive to end the dictation itself.
    var current = current
    readListeningState()
    let appGone = listeningState.map { $0.leaseUntil <= now() } ?? true
    if appGone, current.noticeDwellSeconds == nil, current.state != .idle { current = .idle }
    snapshot = current
    if current.state == .error { heldError = current }
    if wantsHaptics, current.state != previous { haptics(from: previous, to: current.state) }
    // The handshake follows the phase as shown: the press it answers, the
    // dictation it names, the end of one.
    perform(handshake.handle(.phase(current), now: now()))
    // A notice is over after its dwell: the Mac pill fades out, this orb goes
    // back to its resting circle. Only the picture settles — the line for an
    // error stays (`heldError`) until the next tap.
    noticeDwell?.cancel()
    dismissedNoticeAt = nil
    if let seconds = current.noticeDwellSeconds {
      let at = current.at
      noticeDwell = Task { [weak self] in
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled, let self else { return }
        dismissedNoticeAt = at
        snapshot = .idle
      }
    }
    if current.state != previous || noticeClock == nil { runNoticeClock(for: current) }
  }

  package func resultArrived() {
    guard let result = SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) else { return }
    guard result.id != lastResultID else { return }
    guard let proxy else {
      KeyboardLog.result(result.id, inserted: false, why: "no field")
      return
    }
    guard now().timeIntervalSince(result.deliveredAt) < Self.resultFreshnessWindow else {
      KeyboardLog.result(result.id, inserted: false, why: "stale")
      return
    }
    guard result.recipient == nil || result.recipient == KeyboardProcess.id else {
      KeyboardLog.result(result.id, inserted: false, why: "for \(result.recipient ?? "")")
      return
    }
    lastResultID = result.id
    // Taken out of the store once inserted, so no other keyboard process —
    // each host app runs its own — can insert the same words again; the app
    // watches for this removal to know the words landed.
    SharedStore.remove(forKey: BlurtShared.Key.result)
    // Joined against the live text before the cursor, not the press-time
    // snapshot: the user may have typed since.
    let inserted = InsertionSeparator.withLeadingSeparator(result.text, after: proxy.documentContextBeforeInput)
    proxy.insertText(inserted)
    lastInsertion = Insertion(
      text: inserted, document: proxy.documentIdentifier, textAfter: proxy.documentContextAfterInput ?? "")
    resultLandedAt = now()
    KeyboardLog.result(result.id, inserted: true, why: result.recipient == nil ? "for whoever is up" : "addressed here")
    // Not typing, so not the term field's to claim.
    if termDraft != nil { termHostBaseline = proxy.documentContextBeforeInput ?? "" }
    // The words replaced whatever was highlighted: the chip for that word
    // goes now, not on the host's next notification.
    readSelection()
  }

  package func haptics(from previous: PhaseSnapshot.State, to state: PhaseSnapshot.State) {
    guard hasFullAccess else { return }
    switch state {
    case .recording:
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    case .processing where previous == .recording:
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    case .pasted, .copied:
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    case .error:
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    case .idle, .connecting, .processing:
      break
    }
  }
}
