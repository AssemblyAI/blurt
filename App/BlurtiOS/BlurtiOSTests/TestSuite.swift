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

  /// A tap — finger down, finger up — answered by the app's recording phase: the
  /// gate latched over a live dictation.
  func latchRecording() {
    model.micDown()
    model.micUp()
    model.apply(snapshot(.recording))
  }

  /// The app process the fixture's records come from.
  static let launchID = UUID()

  /// The app listening, or not, as the app would write it: the readiness
  /// record (`SharedStore.listeningState`) — open with a live mic, a fresh
  /// lease and ten minutes to go, or closed with the session off — and, for
  /// a reader of the keys that came before it, `listeningUntil` and
  /// `appSeenAt` saying the same.
  static func listening(_ on: Bool) {
    let now = Date()
    SharedStore.listeningState =
      on
      ? ListeningState(
        launchID: launchID, sequence: 1, window: .open, micLive: true, windowUntil: now.addingTimeInterval(600),
        writtenAt: now)
      : ListeningState(launchID: launchID, sequence: 2, window: .closed, reason: .sessionOff, writtenAt: now)
    SharedStore.listeningUntil = on ? now.addingTimeInterval(600) : nil
    SharedStore.appSeenAt = on ? now : nil
  }
}

/// A phase as the app would publish it, now.
@MainActor
func snapshot(_ state: PhaseSnapshot.State, level: Double = 0) -> PhaseSnapshot {
  PhaseSnapshot(state: state, message: nil, level: level, at: Date())
}
