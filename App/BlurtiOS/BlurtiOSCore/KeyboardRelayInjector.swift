import BlurtEngine
import Foundation
import UIKit
import UniformTypeIdentifiers

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

  /// How long a password field's words stay on the clipboard when no keyboard
  /// took them: the engine's `TargetSecurity.concealedClipboardLifetime`, the
  /// Mac's figure, as an iOS expiry.
  package static let secureClipboardLifetime = TimeInterval(
    TargetSecurity.concealedClipboardLifetime.components.seconds
  )

  /// The field the words are for: the one that sent the accepted stop, else
  /// the one whose press started the dictation (`DictationCoordinator`). A nil
  /// keyboard means whichever keyboard is up.
  package var presser: @Sendable () -> ResultAddress = { ResultAddress() }

  /// The clock the delivery waits on: real time, or a test's, so the timeout
  /// and the re-signal are stepped through rather than waited out.
  package let clock: any Clock<Duration> & Sendable

  /// The time a keyboard's presence is judged against: the wall clock, or a
  /// test's fixed instant, so a slow run can't age the keyboard out from under
  /// the words before they are delivered.
  package let now: @Sendable () -> Date

  /// The keyboard process on screen: the presence record's, or — for a
  /// keyboard build that writes none yet — the older heartbeat keys'.
  private var onScreen: String? {
    let instant = now()
    if let record = SharedStore.keyboardOnScreen(now: instant) {
      return record.processID
    }
    return SharedStore.isKeyboardPresent(now: instant) ? SharedStore.keyboardInstance : nil
  }

  package init(
    presser: @escaping @Sendable () -> ResultAddress = { ResultAddress() },
    clock: any Clock<Duration> & Sendable = ContinuousClock(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.presser = presser
    self.clock = clock
    self.now = now
  }

  package func setTarget(_: CapturedFocus?) {
    // Nothing to aim: the keyboard that asked is the target, read from `presser` at insert time.
  }

  /// Only `.secure` conceals here: the keyboard reads the field it is attached
  /// to and says whether it holds a password (`isPasswordField`), and iOS has
  /// no AX-opaque app whose fields could hide one, as the Mac does.
  package func insert(
    _ text: String, after _: String?, windowTitle _: String?, security: TargetSecurity
  ) async throws {
    let secure = security == .secure
    // The words go to the keyboard that asked for them. If the user has
    // moved on — another app's keyboard is the one on screen now — they go
    // to the clipboard rather than into a field nobody dictated into.
    let current = onScreen
    let address = presser()
    let recipient = address.keyboard ?? current
    guard let current, recipient == current else {
      Self.log.notice("result → copied: no keyboard on screen for \(recipient ?? "anyone", privacy: .public)")
      try await copyOut(text, secure: secure)
    }
    let result = DictationResult(
      id: UUID(),
      text: text,
      deliveredAt: Date(),
      recipient: recipient,
      controllerID: address.controllerID,
      documentID: address.documentID
    )
    SharedStore.write(result, forKey: BlurtShared.Key.result)
    SharedStore.post(BlurtShared.Signal.result)
    let waitClock: any Clock<Duration> = clock
    if try await taken(result.id, on: waitClock) {
      Self.log.notice("result \(result.id, privacy: .public) → inserted by \(current, privacy: .public)")
      return
    }
    SharedStore.remove(forKey: BlurtShared.Key.result)
    Self.log.notice("result \(result.id, privacy: .public) → copied: not taken by \(current, privacy: .public)")
    try await copyOut(text, secure: secure)
  }

  /// The keyboard has no other focus to insert at: a voice command's typed
  /// step goes where a dictation's words would.
  package func insertAtFocus(_ text: String) async throws {
    try await insert(text, after: nil, windowTitle: nil, security: .ordinary)
  }

  /// Polls the store until the keyboard has taken result `id` out of it
  /// (true) or the delivery timeout has passed (false), signalling once more
  /// on the way. Generic so the injected clock's instants can be compared.
  private func taken<C: Clock<Duration>>(_ id: UUID, on clock: C) async throws -> Bool {
    let posted = clock.now
    let deadline = posted.advanced(by: .seconds(Self.deliveryTimeout))
    var resignalled = false
    while clock.now < deadline {
      do {
        try await clock.sleep(for: Self.deliveryPoll)
      } catch {
        // A dictation cancelled mid-wait takes its words back: left in the
        // App Group, the keyboard would still insert them into the host app.
        // Only this result, though — a newer one isn't this wait's to drop.
        if SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result)?.id == id {
          SharedStore.remove(forKey: BlurtShared.Key.result)
        }
        throw error
      }
      guard let pending = SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result), pending.id == id
      else {
        return true
      }
      if !resignalled, posted.duration(to: clock.now) >= .seconds(Self.resignalAfter) {
        resignalled = true
        SharedStore.post(BlurtShared.Signal.result)
      }
    }
    return false
  }

  /// The words to the clipboard, and the quiet "Copied" outcome. A password
  /// field's words are kept to this phone (off Universal Clipboard) and expire,
  /// so the secret doesn't sit there for whatever reads the clipboard next.
  private func copyOut(_ text: String, secure: Bool) async throws -> Never {
    await MainActor.run {
      if secure {
        UIPasteboard.general.setItems(
          [[UTType.utf8PlainText.identifier: text]],
          options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(Self.secureClipboardLifetime)]
        )
      } else {
        UIPasteboard.general.string = text
      }
    }
    throw BlurtError.noEditableTarget
  }
}
