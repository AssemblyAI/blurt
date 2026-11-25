import BlurtEngine
import Foundation

// MARK: - Payloads
//
// Every type below is `nonisolated`: both targets default their declarations to
// the main actor (`SWIFT_DEFAULT_ACTOR_ISOLATION`), but these values cross into
// the app's capture path and the engine's closures, which run anywhere.

/// What the keyboard asks the app to do, with the context only the keyboard can
/// see: the text before the cursor primes the transcript exactly as the Mac's
/// Accessibility read does.
package nonisolated struct KeyboardCommand: Codable, Sendable {
  package nonisolated enum Kind: String, Codable, Sendable {
    case press
    case release
    case cancel
  }

  package let id: UUID
  package let kind: Kind
  package let priorText: String?
  package let selectedText: String?
  package let sentAt: Date
  /// The keyboard process that sent it (`KeyboardProcess.id`): the words
  /// come back to the field the press was made in, not whichever is up.
  package let keyboard: String?
  /// Per-process sequence number, so the app can tell a resend from a new
  /// press even if the id were reused.
  package let seq: UInt64?
  /// The controller (one per host field) within the process.
  package let controllerID: String?
  /// The host field itself (`UITextDocumentProxy.documentIdentifier`): iOS
  /// can keep one controller as the user taps from field to field, and this
  /// is what changes then (`ResultAddress`).
  package let documentID: UUID?
  /// For a release or cancel: the dictation it ends (`CommandAck.started`),
  /// so an ending can't land on a later dictation.
  package let dictationID: UUID?
  /// The `ListeningState.sequence` the keyboard decided on, for the log.
  package let stateSequence: UInt64?
  /// For a press: the field is a password field (`UITextDocumentProxy.isPasswordField`).
  /// Its text never rides the command, and the app hands the flag to the
  /// engine (`FocusedFieldContext.isSecure`), so what is dictated into it is
  /// never remembered as context for a later dictation — the Mac's rule.
  /// Nil from a keyboard build that never learned it.
  package let isSecure: Bool?  // swiftlint:disable:this discouraged_optional_boolean

  package init(
    id: UUID,
    kind: Kind,
    priorText: String?,
    selectedText: String?,
    sentAt: Date,
    keyboard: String?,
    seq: UInt64? = nil,
    controllerID: String? = nil,
    documentID: UUID? = nil,
    dictationID: UUID? = nil,
    stateSequence: UInt64? = nil,
    isSecure: Bool? = nil  // swiftlint:disable:this discouraged_optional_boolean
  ) {
    self.id = id
    self.kind = kind
    self.priorText = priorText
    self.selectedText = selectedText
    self.sentAt = sentAt
    self.keyboard = keyboard
    self.seq = seq
    self.controllerID = controllerID
    self.documentID = documentID
    self.dictationID = dictationID
    self.stateSequence = stateSequence
    self.isSecure = isSecure
  }

  /// Young enough for the app to act on. A notification held while the app
  /// was suspended can deliver one from minutes ago, which the app drops
  /// unread — so the keyboard stops waiting for an answer to it, too.
  package func isFresh(now: Date = Date()) -> Bool {
    now.timeIntervalSince(sentAt) < BlurtShared.commandFreshnessWindow
  }
}
