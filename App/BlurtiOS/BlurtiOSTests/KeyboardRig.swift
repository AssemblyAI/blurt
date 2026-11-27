import Foundation
import UIKit

@testable import BlurtiOSCore

/// A keyboard that is ready to dictate — a fake field, Full Access, the app
/// listening (an open window with a fresh lease) — with every command it
/// sends captured instead of reaching the App Group, and the app's answers
/// written the way the app writes them, into the test's own `store`.
@MainActor
struct KeyboardRig {
  final class Commands {
    var sent: [KeyboardCommand] = []
  }

  /// A controller in a window, so the model's hop can walk the responder
  /// chain to the application; what it asked to open is captured here.
  final class Hops {
    var opened: [URL] = []
  }

  /// The app process the rig stands in for: on the record and every ack.
  static let launch = UUID()

  let store: SharedStore
  let model: KeyboardModel
  let proxy: FakeProxy
  let commands: Commands

  /// The last press this keyboard sent, if any.
  var lastPress: KeyboardCommand? { commands.sent.last { $0.kind == .press } }

  init(store: SharedStore, proxy: FakeProxy = FakeProxy()) {
    let keyboard = KeyboardModel(store: store)
    keyboard.proxyOverride = proxy
    keyboard.hasFullAccess = true
    // Time stands still unless a test moves it (`model.now = { … }`): on the
    // wall clock a slow runner — ASan, a loaded CI host — can let more than
    // the hold threshold pass between a tap's micDown and micUp, and a tap
    // read as a hold sends a release nobody asked for.
    let start = Date()
    keyboard.now = { start }
    Self.listening(true, in: store)
    keyboard.readListeningState()
    let sentCommands = Commands()
    keyboard.transport = { sentCommands.sent.append($0) }
    self.store = store
    self.model = keyboard
    self.proxy = proxy
    self.commands = sentCommands
  }

  /// The app listening — an open window with a live mic and a fresh lease,
  /// written as `ListeningState` and as the older keys a build before the
  /// record still reads — or a closed one, in `store`.
  static func listening(_ on: Bool, in store: SharedStore, now: Date = Date()) {
    store.listeningUntil = on ? now.addingTimeInterval(600) : nil
    store.appSeenAt = on ? now : nil
    store.listeningState = ListeningState(
      launchID: launch,
      sequence: nextSequence(in: store),
      window: on ? .open : .closed,
      micLive: on,
      reason: on ? nil : .sessionOff,
      writtenAt: now
    )
  }

  /// A record in any state, in `store`, with the lease fresh unless `age` says otherwise.
  static func record(
    _ window: ListeningState.Window,
    in store: SharedStore,
    micLive: Bool = false,
    reason: FailureReason? = nil,
    age: TimeInterval = 0,
    now: Date = Date()
  ) {
    store.listeningState = ListeningState(
      launchID: launch,
      sequence: nextSequence(in: store),
      window: window,
      micLive: micLive,
      reason: reason,
      writtenAt: now.addingTimeInterval(-age)
    )
  }

  /// The record's next sequence: one past the last written to `store`,
  /// climbing with every write as the app's does.
  private static func nextSequence(in store: SharedStore) -> UInt64 {
    (store.listeningState?.sequence ?? 0) + 1
  }

  /// The app answers a command — the last one sent unless named — with
  /// `outcome`: the ack written and the model told, as `Signal.ack` would.
  func answer(_ outcome: CommandAck.Outcome, to command: KeyboardCommand? = nil) {
    guard let answered = command ?? commands.sent.last else {
      return
    }
    store.acknowledge(CommandAck(commandID: answered.id, launchID: Self.launch, outcome: outcome))
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

  /// The recording phase published for `dictation`, then the tap that stops
  /// it: the release this keyboard sent, which names the dictation.
  func tapToStop(_ dictation: UUID) -> KeyboardCommand? {
    model.apply(snapshot(.recording, dictation: dictation))
    model.tapMic()
    return commands.sent.last
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
}
