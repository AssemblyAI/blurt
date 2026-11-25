import Foundation

/// The dictation a phase or a command refers to, and the keyboard process
/// whose press started it — the only one (besides whoever is on screen) that
/// may end it.
package nonisolated struct DictationRef: Codable, Sendable, Equatable {
  package let id: UUID
  package let ownerProcessID: String?

  package init(id: UUID, ownerProcessID: String?) {
    self.id = id
    self.ownerProcessID = ownerProcessID
  }
}
