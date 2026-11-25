import Foundation

/// Which keyboard is on screen: one record, compare-and-written by its own
/// process only, so a keyboard leaving in one host can't erase the one that
/// just appeared in another.
package nonisolated struct KeyboardPresenceRecord: Codable, Sendable, Equatable {
  package let processID: String
  package let controllerID: String
  package let pid: Int32
  package let seenAt: Date
  package let onScreen: Bool

  package init(processID: String, controllerID: String, pid: Int32, onScreen: Bool, seenAt: Date = Date()) {
    self.processID = processID
    self.controllerID = controllerID
    self.pid = pid
    self.seenAt = seenAt
    self.onScreen = onScreen
  }

  /// Still counts as present (`BlurtShared.presenceWindow`).
  package func isFresh(now: Date = Date()) -> Bool {
    now.timeIntervalSince(seenAt) < SharedStore.presenceWindow
  }
}
