import BlurtEngine
import Foundation
import UIKit

/// The engine's paste seam on iPhone. Nothing here can type into another app;
/// only the keyboard can, so "insert" means hand the words to the keyboard and
/// ping it. When no keyboard is around to take them — it was dismissed, or the
/// dictation was started from the app itself — the words go to the clipboard
/// instead and the pipeline shows its quiet "Copied" notice, exactly the
/// degradation the Mac uses when nothing editable is focused.
///
/// The text goes over as returned: the keyboard applies
/// `InsertionSeparator.withLeadingSeparator` against the *live* text before the
/// cursor, which may have moved since the press.
nonisolated struct KeyboardRelayInjector: InjectorProtocol {
  /// How recently the keyboard must have checked in to count as present. Its
  /// heartbeat is every few seconds while it is on screen.
  static let keyboardPresenceWindow: TimeInterval = 15

  func setTarget(_ focus: CapturedFocus?) async {}

  func insert(_ text: String, after priorText: String?, windowTitle: String?) async throws {
    let result = DictationResult(id: UUID(), text: text, deliveredAt: Date())
    SharedStore.write(result, forKey: BlurtShared.Key.result)
    SharedStore.post(BlurtShared.Signal.result)
    let seen = SharedStore.keyboardSeenAt ?? .distantPast
    guard Date().timeIntervalSince(seen) < Self.keyboardPresenceWindow else {
      await MainActor.run { UIPasteboard.general.string = text }
      throw BlurtError.noEditableTarget
    }
  }
}
