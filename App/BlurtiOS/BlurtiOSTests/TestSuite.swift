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

/// A keyboard that is ready to dictate — a fake field, Full Access, the app
/// listening for the next ten minutes — with every command it sends captured
/// instead of reaching the App Group. Build it after `ScratchSuite`: the
/// listening window it opens is written to the store.
@MainActor
struct KeyboardRig {
  final class Commands {
    var sent: [KeyboardCommand] = []
  }

  let model: KeyboardModel
  let proxy: FakeProxy
  let commands: Commands

  init(proxy: FakeProxy = FakeProxy()) {
    let model = KeyboardModel()
    model.proxyOverride = proxy
    model.hasFullAccess = true
    Self.listening(true)
    model.isListening = true
    let commands = Commands()
    model.transport = { commands.sent.append($0) }
    self.model = model
    self.proxy = proxy
    self.commands = commands
  }

  /// The app listening — an open window and a fresh heartbeat — or not.
  static func listening(_ on: Bool) {
    let now = Date()
    SharedStore.listeningUntil = on ? now.addingTimeInterval(600) : nil
    SharedStore.appSeenAt = on ? now : nil
  }
}

/// A phase as the app would publish it, now.
@MainActor
func snapshot(_ state: PhaseSnapshot.State, level: Double = 0) -> PhaseSnapshot {
  PhaseSnapshot(state: state, message: nil, level: level, at: Date())
}
