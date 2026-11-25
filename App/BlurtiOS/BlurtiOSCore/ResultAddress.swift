import BlurtEngine
import Foundation

/// Where a dictation's words go: the field the accepted stop came from, else
/// the one the press did (DESIGN.md › result addressing), named three ways.
/// The keyboard process keeps a second host app's keyboard out; the
/// controller and the document keep out another field in the same process,
/// which is where words used to land when the user tapped away while they
/// were still being transcribed (#346). Nil in any part — a keyboard build
/// that never sent it — matches anything there.
package nonisolated struct ResultAddress: Sendable, Equatable {
  package var keyboard: String?
  package var controllerID: String?
  package var documentID: UUID?

  package init(keyboard: String? = nil, controllerID: String? = nil, documentID: UUID? = nil) {
    self.keyboard = keyboard
    self.controllerID = controllerID
    self.documentID = documentID
  }

  /// The field the command was sent from.
  package init(_ command: KeyboardCommand) {
    self.init(keyboard: command.keyboard, controllerID: command.controllerID, documentID: command.documentID)
  }
}
