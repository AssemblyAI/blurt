import BlurtEngine
import Foundation
import Testing

@testable import BlurtiOS
@testable import BlurtiOSCore

/// The coordinator over a faked window and an in-memory key: what a launch
/// writes, and how a command is answered without the session hearing of it.
/// The router's rows are `CommandRouterTests`; this is the ack path around it.
/// A press the session does take, and what follows it, is
/// `DictationCoordinatorTests+Dictation.swift`.
@Suite("Dictation coordinator", .serialized)
@MainActor
struct DictationCoordinatorTests {
  /// The words every stub transcript carries.
  static let transcript = "hello there"

  /// A coordinator over a rig's window, transcribing offline and ticking on
  /// the rig's clock. `startDelay` holds a press's start, so `.connecting`
  /// can be seen; `closeDelay` holds the source's close, so a press can land
  /// while the window is closing.
  func coordinator(startDelay: Duration = .zero, closeDelay: Duration = .zero) -> (DictationCoordinator, WindowRig) {
    let rig = WindowRig(closeDelay: closeDelay, startDelay: startDelay)
    let coordinator = DictationCoordinator(
      apiKey: APIKeyModel(keyStore: InMemoryAPIKeyStore()), window: rig.window,
      transcriber: StubTranscriber(text: Self.transcript), clock: rig.clock)
    return (coordinator, rig)
  }

  func command(_ kind: KeyboardCommand.Kind, id: UUID = UUID(), keyboard: String = "kb-1") -> KeyboardCommand {
    KeyboardCommand(id: id, kind: kind, priorText: "Hi", selectedText: nil, sentAt: Date(), keyboard: keyboard)
  }

  /// Writes the command where the keyboard would and lets the coordinator take it.
  func send(_ command: KeyboardCommand, to coordinator: DictationCoordinator) {
    SharedStore.write(command, forKey: BlurtShared.Key.command)
    coordinator.handleCommand()
  }

  @Test("start writes a fresh launch: no window, sequence 0, and the phase idle under it")
  func start() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.listeningState = ListeningState(launchID: UUID(), sequence: 9, window: .open, micLive: true)
    let (coordinator, rig) = coordinator()
    coordinator.start()
    let record = SharedStore.listeningState
    #expect(record?.window == .closed)
    #expect(record?.sequence == 0)
    #expect(record?.launchID == rig.window.launchID)
    #expect(record?.reason == .sessionOff)
    #expect(rig.state == record, "the window's own, so its beats renew it")
    #expect(!SharedStore.isListening)
    let phase = SharedStore.read(PhaseSnapshot.self, forKey: BlurtShared.Key.phase)
    #expect(phase?.state == .idle)
    #expect(phase?.launchID == rig.window.launchID)
    #expect(phase?.dictation == nil && phase?.answers == nil)
  }

  @Test("a press to a closed window is acked notListening and never submitted; its resend is answered the same")
  func pressToClosedWindow() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (coordinator, rig) = coordinator()
    coordinator.start()
    let press = command(.press)
    send(press, to: coordinator)
    let ack = SharedStore.commandAck
    #expect(ack?.commandID == press.id)
    #expect(ack?.outcome == .notListening(.sessionOff))
    #expect(ack?.launchID == rig.window.launchID)
    #expect(SharedStore.read(KeyboardCommand.self, forKey: BlurtShared.Key.command) == nil, "consumed")
    #expect(coordinator.inFlight == nil)
    #expect(coordinator.answers == nil)
    #expect(coordinator.lastCommandID == nil)
    try? await Task.sleep(for: .milliseconds(200))
    #expect(coordinator.phase == .idle, "nothing reached the session")
    #expect(rig.source.started == 0)
    // The same press again — a missed ack — gets the same answer and nothing more.
    SharedStore.commandAck = nil
    send(press, to: coordinator)
    #expect(SharedStore.commandAck?.outcome == .notListening(.sessionOff))
    #expect(coordinator.answered.count == 1)
  }

  @Test("a press while the window is closing is refused on the window as it is, never promised the mic on its way out")
  func pressWhileClosing() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (coordinator, rig) = coordinator(closeDelay: .milliseconds(400))
    coordinator.start()
    coordinator.apiKey.save("key")
    #expect(await rig.opened())
    rig.window.close()
    #expect(await until { rig.window.liveState.window == .closing })
    let press = command(.press)
    send(press, to: coordinator)
    #expect(SharedStore.commandAck?.commandID == press.id)
    #expect(SharedStore.commandAck?.outcome == .notListening(.sessionOff))
    #expect(coordinator.inFlight == nil && coordinator.answers == nil)
    #expect(rig.source.started == 0, "nothing submitted")
    #expect(await until { rig.state?.window == .closed })
    #expect(coordinator.phase == .idle)
  }

  @Test("a release or cancel with nothing in flight is acked nothingInFlight")
  func endingNothing() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (coordinator, _) = coordinator()
    coordinator.start()
    let release = command(.release)
    send(release, to: coordinator)
    #expect(SharedStore.commandAck?.outcome == .nothingInFlight)
    let cancel = command(.cancel)
    send(cancel, to: coordinator)
    #expect(SharedStore.commandAck?.commandID == cancel.id)
    #expect(SharedStore.commandAck?.outcome == .nothingInFlight)
    #expect(coordinator.lastCommandID == nil)
  }

  @Test("the answered ids are bounded: the oldest make room, and a resend of one of those is decided afresh")
  func answeredBounded() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (coordinator, _) = coordinator()
    coordinator.start()
    let first = command(.press)
    send(first, to: coordinator)
    for _ in 0..<DictationCoordinator.answeredCapacity { send(command(.press), to: coordinator) }
    #expect(coordinator.answered.count == DictationCoordinator.answeredCapacity)
    #expect(coordinator.answered[first.id] == nil)
    // Decided afresh means answered from the record, which still says the session is off.
    send(first, to: coordinator)
    #expect(SharedStore.commandAck?.outcome == .notListening(.sessionOff))
    #expect(coordinator.answered.count == DictationCoordinator.answeredCapacity)
  }

  @Test("the setup hop sets the Full Access flag and opens no window; the start hop asks for one")
  func hops() async {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (coordinator, rig) = coordinator()
    coordinator.start()
    coordinator.handle(BlurtShared.setupURL(need: BlurtShared.fullAccessNeed))
    #expect(coordinator.needsFullAccess)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(rig.source.opened == 0)
    #expect(rig.state?.window == .closed && rig.state?.sequence == 0, "the window published only its launch")
    #expect(SharedStore.listeningState?.window == .closed)
    SessionAutoStart.setTurnedOff(true)
    coordinator.handle(BlurtShared.startURL(reason: .sessionOff))
    #expect(!SessionAutoStart.isTurnedOff(), "the keyboard's ask undoes an earlier off")
    // No key in the in-memory store: the hop stops at the key, with no window.
    #expect(await until { coordinator.needsKey })
    #expect(rig.source.opened == 0)
    SessionAutoStart.setTurnedOff(false)
  }

  @Test("the watchdog's tick keeps a dead keyboard's dictation inside the row: released within the watchdog and a tick")
  func watchdogCadence() {
    #expect(DictationCoordinator.watchdogTick == .seconds(2))
    #expect(BlurtShared.ownerWatchdog + 2 <= 12)
    #expect(DictationCoordinator.watchdogTick < .seconds(SharedStore.keyboardHeartbeatInterval))
  }
}

/// The device trace's line: one JSON object per event, the fields given and
/// nothing else, newline-terminated — and off unless the launch argument says.
@Suite("Device trace")
struct DeviceTraceTests {
  @Test("a line is one JSON object with the kind, the time and the fields, and ends the line")
  func line() throws {
    let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let line = DeviceTrace.line("press", ["id": "abc", "outcome": "started"], at: at)
    #expect(line.last == UInt8(ascii: "\n"))
    let object = try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: String]
    #expect(object?["kind"] == "press")
    #expect(object?["id"] == "abc")
    #expect(object?["outcome"] == "started")
    #expect(object?["t"]?.hasPrefix("2026-05-") == true)
    #expect(object?.count == 4)
    #expect(!DeviceTrace.isEnabled, "off unless -BlurtDeviceTrace YES")
    #expect(DeviceTrace.url.lastPathComponent == DeviceTrace.fileName)
  }
}
