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
  /// A result not taken by then is signalled once more: a Darwin
  /// notification can be missed, and a second one costs nothing (DESIGN.md).
  package static let resignalAfter: TimeInterval = 1
  private static let log = HostIdentity.current.logger("Relay")

  /// The field the words are for: the keyboard process and controller that
  /// sent the accepted stop, else the press that started the dictation
  /// (`DictationCoordinator`), or nil for whichever keyboard is up.
  package var presser: @Sendable () -> KeyboardAddress? = { nil }

  package init(presser: @escaping @Sendable () -> KeyboardAddress? = { nil }) {
    self.presser = presser
  }

  package func setTarget(_ focus: CapturedFocus?) async {}

  package func insert(_ text: String, after priorText: String?, windowTitle: String?) async throws {
    // The words go to the field that asked for them. If the user has moved
    // on — another app's keyboard is the one on screen now, or another
    // field's controller in the same one — they go to the clipboard rather
    // than into a field nobody dictated into.
    let target = presser()
    let onScreen = Self.onScreen
    let recipient = target?.process ?? onScreen?.process
    guard let onScreen, recipient == onScreen.process, Self.sameField(target?.controller, onScreen.controller) else {
      let why = onScreen?.process == recipient && recipient != nil ? "another field up in" : "no keyboard on screen for"
      Self.log.notice("result → copied: \(why, privacy: .public) \(recipient ?? "anyone", privacy: .public)")
      try await copyOut(text)
    }
    let result = DictationResult(
      id: UUID(), text: text, deliveredAt: Date(), recipient: recipient, controllerID: target?.controller)
    SharedStore.write(result, forKey: BlurtShared.Key.result)
    SharedStore.post(BlurtShared.Signal.result)
    let posted = Date()
    let deadline = posted.addingTimeInterval(Self.deliveryTimeout)
    var resignalled = false
    while Date() < deadline {
      try await Task.sleep(for: Self.deliveryPoll)
      guard let pending = SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result),
        pending.id == result.id
      else {
        Self.log.notice(
          "result \(result.id, privacy: .public) → inserted by \(onScreen.process, privacy: .public)")
        return
      }
      if !resignalled, Date().timeIntervalSince(posted) >= Self.resignalAfter {
        resignalled = true
        SharedStore.post(BlurtShared.Signal.result)
      }
    }
    SharedStore.remove(forKey: BlurtShared.Key.result)
    Self.log.notice(
      "result \(result.id, privacy: .public) → copied: not taken by \(onScreen.process, privacy: .public)")
    try await copyOut(text)
  }

  /// The keyboard on screen: the presence record's process and controller,
  /// or — for a keyboard build that writes no record yet — the older
  /// heartbeat keys' process, with no controller known.
  private static var onScreen: KeyboardAddress? {
    if let record = SharedStore.keyboardOnScreen() {
      return KeyboardAddress(process: record.processID, controller: record.controllerID)
    }
    guard SharedStore.isKeyboardPresent, let process = SharedStore.keyboardInstance else { return nil }
    return KeyboardAddress(process: process)
  }

  /// Whether the field on screen is the one the words are for. Only a known
  /// controller on both sides can differ: either side unnamed (an older
  /// keyboard build, the heartbeat keys) is taken as the same field.
  private static func sameField(_ target: String?, _ onScreen: String?) -> Bool {
    guard let target, let onScreen else { return true }
    return target == onScreen
  }

  /// The words to the clipboard, and the quiet "Copied" outcome.
  private func copyOut(_ text: String) async throws -> Never {
    await MainActor.run { UIPasteboard.general.string = text }
    throw BlurtError.noEditableTarget
  }
}
