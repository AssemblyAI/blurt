import Foundation
import UIKit

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
/// listening (an open window with a fresh lease) — with every command it
/// sends captured instead of reaching the App Group, and the app's answers
/// written the way the app writes them. Build it after `ScratchSuite`: the
/// record it writes goes to the store.
@MainActor
struct KeyboardRig {
  final class Commands {
    var sent: [KeyboardCommand] = []
  }

  /// The app process the rig stands in for: on the record and every ack.
  static let launch = UUID()
  /// The record's sequence, climbing with every write as the app's does.
  private static var sequence: UInt64 = 0

  let model: KeyboardModel
  let proxy: FakeProxy
  let commands: Commands

  init(proxy: FakeProxy = FakeProxy()) {
    let model = KeyboardModel()
    model.proxyOverride = proxy
    model.hasFullAccess = true
    Self.listening(true)
    model.readListeningState()
    let commands = Commands()
    model.transport = { commands.sent.append($0) }
    self.model = model
    self.proxy = proxy
    self.commands = commands
  }

  /// The last press this keyboard sent, if any.
  var lastPress: KeyboardCommand? { commands.sent.last { $0.kind == .press } }

  /// The app answers a command — the last one sent unless named — with
  /// `outcome`: the ack written and the model told, as `Signal.ack` would.
  func answer(_ outcome: CommandAck.Outcome, to command: KeyboardCommand? = nil) {
    guard let command = command ?? commands.sent.last else { return }
    SharedStore.acknowledge(CommandAck(commandID: command.id, launchID: Self.launch, outcome: outcome))
    model.ackArrived()
  }

  /// A tap — finger down, finger up — answered by the app: the press acked
  /// `started`, then the recording phase published for the dictation. The
  /// gate is latched over a live dictation this keyboard owns.
  @discardableResult
  func latchRecording() -> UUID {
    model.tapMic()
    let dictation = UUID()
    answer(.started(dictation))
    model.apply(snapshot(.recording, dictation: dictation))
    return dictation
  }

  /// A controller in a window, so the model's hop can walk the responder
  /// chain to the application; what it asked to open is captured here.
  final class Hops {
    var opened: [URL] = []
  }

  /// Puts the model's controller in a window and captures every URL the
  /// model asks the application to open. The window is hidden again when
  /// the returned handle goes.
  func capturingHops() -> (Hops, UIWindow) {
    let hops = Hops()
    model.urlOpener = { _, url in hops.opened.append(url) }
    let controller = UIInputViewController(nibName: nil, bundle: nil)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    window.rootViewController = controller
    window.isHidden = false
    model.controller = controller
    return (hops, window)
  }

  /// The app listening — an open window with a live mic and a fresh lease,
  /// written as `ListeningState` and as the older keys a build before the
  /// record still reads — or a closed one.
  static func listening(_ on: Bool, now: Date = Date()) {
    SharedStore.listeningUntil = on ? now.addingTimeInterval(600) : nil
    SharedStore.appSeenAt = on ? now : nil
    sequence += 1
    SharedStore.listeningState = ListeningState(
      launchID: launch, sequence: sequence, window: on ? .open : .closed, micLive: on,
      reason: on ? nil : .sessionOff, writtenAt: now)
  }

  /// A record in any state, with the lease fresh unless `age` says otherwise.
  static func record(
    _ window: ListeningState.Window, micLive: Bool = false, reason: FailureReason? = nil, age: TimeInterval = 0
  ) {
    sequence += 1
    SharedStore.listeningState = ListeningState(
      launchID: launch, sequence: sequence, window: window, micLive: micLive, reason: reason,
      writtenAt: Date().addingTimeInterval(-age))
  }
}

/// A phase as the app would publish it, now: `dictation` names the one in
/// flight, `answers` the press it answers.
@MainActor
func snapshot(
  _ state: PhaseSnapshot.State, level: Double = 0, dictation: UUID? = nil, answers: UUID? = nil,
  reason: FailureReason? = nil
) -> PhaseSnapshot {
  PhaseSnapshot(
    state: state, message: nil, level: level, at: Date(), reason: reason, answers: answers,
    dictation: dictation.map { DictationRef(id: $0, ownerProcessID: KeyboardProcess.id) })
}
