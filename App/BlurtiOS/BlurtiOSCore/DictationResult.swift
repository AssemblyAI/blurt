import Foundation

/// The words the app got back, for the keyboard to insert. The keyboard joins
/// them onto the live text before the cursor itself (`InsertionSeparator`),
/// since the user may have typed since the press.
package nonisolated struct DictationResult: Codable, Sendable {
  package let id: UUID
  package let text: String
  package let deliveredAt: Date
  /// The keyboard instance the words are for — the one whose heartbeat the
  /// app last saw — so a second live keyboard in another app doesn't also
  /// insert them. Nil means whoever is up.
  package let recipient: String?
  /// The controller and the field within `recipient` (`ResultAddress`): a
  /// keyboard in the right process but over another field leaves the words
  /// alone, and the app copies them out when nobody takes them.
  package let controllerID: String?
  package let documentID: UUID?

  package init(
    id: UUID,
    text: String,
    deliveredAt: Date,
    recipient: String?,
    controllerID: String? = nil,
    documentID: UUID? = nil
  ) {
    self.id = id
    self.text = text
    self.deliveredAt = deliveredAt
    self.recipient = recipient
    self.controllerID = controllerID
    self.documentID = documentID
  }

  /// Whether these words are for the field a keyboard is over now — its
  /// controller and the document its proxy is attached to.
  package func isFor(controllerID: String, documentID: UUID?) -> Bool {
    guard self.controllerID == nil || self.controllerID == controllerID else {
      return false
    }
    return self.documentID == nil || self.documentID == documentID
  }
}
