import Foundation

@testable import BlurtiOSCore

/// A throwaway App Group for one test: nothing a test writes reaches the real
/// suite the installed app and keyboard share (the engine's own rule about
/// never touching the real Keychain in tests, applied here).
@MainActor
struct ScratchSuite {
  let name: String

  init() {
    name = "test-\(UUID().uuidString)"
    SharedStore.override = UserDefaults(suiteName: name)
  }

  func tearDown() {
    SharedStore.override?.removePersistentDomain(forName: name)
    SharedStore.override = nil
  }
}
