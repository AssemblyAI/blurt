import BlurtEngine
import Foundation
import UIKit

/// The engine's paste seam on iPhone. Nothing here can type into another app;
/// only the keyboard can, so "insert" means hand the words to the keyboard
/// and ping it — then make sure they arrived. The keyboard takes the result
/// out of the App Group once it has inserted it; if it hasn't within a few
/// seconds (it was dismissed, suspended with its app, or killed), or if no
/// keyboard is on screen at all, the words go to the clipboard instead and
/// the pipeline shows its quiet "Copied" — the degradation the Mac uses when
/// nothing editable is focused — rather than a "Pasted" nobody saw.
///
/// The text goes over as returned: the keyboard applies
/// `InsertionSeparator.withLeadingSeparator` against the *live* text before the
/// cursor, which may have moved since the press.
package nonisolated struct KeyboardRelayInjector: InjectorProtocol {
  /// How long the keyboard gets to insert before the clipboard takes over.
  package static let deliveryTimeout: TimeInterval = 3
  package static let deliveryPoll: Duration = .milliseconds(250)

  /// The keyboard the dictation in flight was pressed in
  /// (`KeyboardCommand.keyboard`), or nil for whichever keyboard is up.
  package var presser: @Sendable () -> String? = { nil }

  package init(presser: @escaping @Sendable () -> String? = { nil }) {
    self.presser = presser
  }

  package func setTarget(_ focus: CapturedFocus?) async {}

  package func insert(_ text: String, after priorText: String?, windowTitle: String?) async throws {
    // The words go to the keyboard that asked for them. If the user has
    // moved on — another app's keyboard is the one on screen now — they go
    // to the clipboard rather than into a field nobody dictated into.
    let onScreen = SharedStore.keyboardInstance
    let recipient = presser() ?? onScreen
    guard SharedStore.isKeyboardPresent, recipient == onScreen else { try await copyOut(text) }
    let result = DictationResult(id: UUID(), text: text, deliveredAt: Date(), recipient: recipient)
    SharedStore.write(result, forKey: BlurtShared.Key.result)
    SharedStore.post(BlurtShared.Signal.result)
    let deadline = Date().addingTimeInterval(Self.deliveryTimeout)
    while Date() < deadline {
      try await Task.sleep(for: Self.deliveryPoll)
      guard let pending = SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result),
        pending.id == result.id
      else { return }
    }
    SharedStore.remove(forKey: BlurtShared.Key.result)
    try await copyOut(text)
  }

  /// The words to the clipboard, and the quiet "Copied" outcome.
  private func copyOut(_ text: String) async throws -> Never {
    await MainActor.run { UIPasteboard.general.string = text }
    throw BlurtError.noEditableTarget
  }
}
