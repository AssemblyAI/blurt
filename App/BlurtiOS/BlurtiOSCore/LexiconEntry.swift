import BlurtEngine
import Foundation

/// One entry of the phone's own word list (`UILexicon`): contact names and the
/// user's text replacements. Names go to the request as key terms so they come
/// back spelled right; replacements are the phone's own text shortcuts.
package nonisolated struct LexiconEntry: Codable, Sendable {
  package let userInput: String
  package let documentText: String

  /// Contact names come through with both fields equal; a text replacement
  /// has a shortcut on one side and its expansion on the other.
  package var isName: Bool { userInput == documentText }
}
