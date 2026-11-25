@testable import BlurtiOS

/// Background tasks as a ledger: what was begun and what was ended, by name.
@MainActor
final class FakeBackgroundTasks: BackgroundTasking {
  private(set) var begun: [String] = []
  private(set) var ended: [String] = []

  func begin(_ name: String) { begun.append(name) }

  func end(_ name: String) { ended.append(name) }
}
