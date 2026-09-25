import BlurtEngine
import Foundation
import UIKit

// MARK: - What comes back from the app: phase, results, haptics

extension KeyboardModel {
  func phaseChanged() {
    guard let current = SharedStore.read(PhaseSnapshot.self, forKey: BlurtShared.Key.phase) else { return }
    apply(current.isStale ? .idle : current)
  }

  func apply(_ current: PhaseSnapshot, haptics wantsHaptics: Bool = true) {
    let previous = snapshot.state
    snapshot = current
    isListening = SharedStore.isListening
    if wantsHaptics, current.state != previous { haptics(from: previous, to: current.state) }
    // The gate follows the app, both ways. A dictation that ended without a
    // finger event (auto-release, an error) would leave it latched and swallow
    // the next tap — the same sync the Mac shell does on every terminal phase.
    // And a dictation in flight that this keyboard didn't start (hands-free
    // in another app, or a previous keyboard process) must latch it, so the
    // next tap is the stop rather than a press the engine drops.
    if isSettled, !gate.isIdle {
      gate.reset()
    } else if !isSettled, gate.isIdle, current.state != .processing {
      // Only a recording (or one coming up) can be stopped by a tap; while
      // the words are being transcribed there is nothing for the gate to hold.
      _ = gate.modifierDown(at: elapsed)
      _ = gate.modifierUp(at: elapsed)
    }
    // A notice is over after its dwell: the Mac pill fades out, this orb goes
    // back to its resting circle. Only the picture settles — a gate latched by
    // a tap the app hasn't answered yet is left alone.
    noticeDwell?.cancel()
    if let seconds = current.noticeDwellSeconds {
      noticeDwell = Task { [weak self] in
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return }
        self?.snapshot = .idle
      }
    }
  }

  func resultArrived() {
    guard let result = SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result),
      result.id != lastResultID, let proxy,
      Date().timeIntervalSince(result.deliveredAt) < Self.resultFreshnessWindow,
      result.recipient == nil || result.recipient == instanceID
    else { return }
    lastResultID = result.id
    // Taken out of the store once inserted, so no other keyboard process —
    // each host app runs its own — can insert the same words again; the app
    // watches for this removal to know the words landed.
    SharedStore.remove(forKey: BlurtShared.Key.result)
    // Joined against the live text before the cursor, not the press-time
    // snapshot: the user may have typed since.
    proxy.insertText(InsertionSeparator.withLeadingSeparator(result.text, after: proxy.documentContextBeforeInput))
    resultLandedAt = Date()
    // Not typing, so not the term field's to claim.
    if termDraft != nil { termHostBaseline = proxy.documentContextBeforeInput ?? "" }
  }

  func haptics(from previous: PhaseSnapshot.State, to state: PhaseSnapshot.State) {
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
