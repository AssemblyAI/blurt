import BlurtEngine
import Foundation
import Testing

@testable import BlurtiOS
@testable import BlurtiOSCore

// MARK: - A press the session takes
//
// The coordinator over the real session, the fake window and a stub
// transcript: the press accepted and owned, the phases it publishes, the
// release from its owner and from a stranger, the watchdog over a keyboard
// gone — and not over a stop already accepted — and a resend.

extension DictationCoordinatorTests {
  /// The keyboard process the rig's presses come from.
  static let keyboard = "kb-1"

  /// A coordinator listening, with a key saved and `keyboard` on screen —
  /// the state a press records from.
  func listening(startDelay: Duration = .zero) async -> (DictationCoordinator, WindowRig) {
    let (coordinator, rig) = coordinator(startDelay: startDelay)
    coordinator.start()
    coordinator.apiKey.save("key")
    #expect(await rig.opened())
    onScreen(Self.keyboard)
    return (coordinator, rig)
  }

  /// `keyboard` on screen, its presence `age` old.
  func onScreen(_ keyboard: String, age: TimeInterval = 0) {
    SharedStore.writeKeyboardPresence(
      KeyboardPresenceRecord(
        processID: keyboard, controllerID: "field", pid: 1, seenAt: Date().addingTimeInterval(-age), onScreen: true))
  }

  /// The phase the keyboard reads.
  var published: PhaseSnapshot? { SharedStore.read(PhaseSnapshot.self, forKey: BlurtShared.Key.phase) }

  /// Presses and waits for the recording; the dictation's id.
  func recording(_ coordinator: DictationCoordinator) async throws -> UUID {
    send(command(.press), to: coordinator)
    let dictation = try #require(coordinator.inFlight?.id)
    #expect(await until { self.published?.state == .recording })
    return dictation
  }

  /// The keyboard takes the result, as it would on `Signal.result`.
  func takeResult() async -> DictationResult? {
    let arrived = await until { SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) != nil }
    guard arrived else { return nil }
    let result = SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result)
    SharedStore.remove(forKey: BlurtShared.Key.result)
    return result
  }

  @Test("an accepted press: started(d), owned by the keyboard that pressed, and every phase names it")
  func acceptedPress() async throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (coordinator, rig) = await listening(startDelay: .milliseconds(200))
    let press = command(.press)
    send(press, to: coordinator)
    let dictation = try #require(coordinator.inFlight?.id)
    #expect(SharedStore.commandAck?.outcome == .started(dictation))
    #expect(coordinator.inFlight == DictationRef(id: dictation, ownerProcessID: Self.keyboard))
    #expect(coordinator.answers == press.id && coordinator.lastCommandID == press.id)
    #expect(coordinator.watchdog != nil, "watched from the press")
    #expect(await until { self.published?.state == .connecting })
    let connecting = try #require(published)
    #expect(connecting.answers == press.id && connecting.command == press.id)
    #expect(connecting.dictation == DictationRef(id: dictation, ownerProcessID: Self.keyboard))
    #expect(connecting.recordingSince == nil && connecting.launchID == rig.window.launchID)
    #expect(await until { self.published?.state == .recording })
    let recording = try #require(published)
    #expect(recording.answers == press.id && recording.dictation?.id == dictation)
    #expect(recording.recordingSince != nil && coordinator.recordingSince != nil)
    #expect(rig.source.started == 1 && rig.idle.began == 1)
    send(command(.cancel), to: coordinator)
    #expect(await until { coordinator.phase == .cancelled })
  }

  @Test("a release from the owner: stopped(d), the words addressed to that keyboard, and the dictation over")
  func ownerRelease() async throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (coordinator, rig) = await listening()
    let dictation = try await recording(coordinator)
    let release = command(.release)
    send(release, to: coordinator)
    #expect(SharedStore.commandAck?.outcome == .stopped(dictation))
    #expect(coordinator.stopAccepted == dictation && coordinator.lastCommandID == release.id)
    #expect(DictationCoordinator.claimedPress.withLock { $0.stopRecipient } == Self.keyboard)
    let result = await takeResult()
    #expect(result?.recipient == Self.keyboard && result?.text == Self.transcript)
    #expect(await until { coordinator.phase == .pasted })
    #expect(published?.state == .pasted && published?.dictation?.id == dictation)
    #expect(coordinator.inFlight == nil && coordinator.answers == nil && coordinator.stopAccepted == nil)
    #expect(coordinator.watchdog == nil)
    #expect(DictationCoordinator.claimedPress.withLock { $0.stopRecipient } == nil)
    #expect(rig.idle.ended == 1 && rig.tasks.ended.contains(DictationCoordinator.releaseTask))
  }

  @Test("a release from a keyboard that neither owns the dictation nor is on screen is notOwner")
  func strangerRelease() async throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (coordinator, _) = await listening()
    let dictation = try await recording(coordinator)
    let release = command(.release, keyboard: "kb-2")
    send(release, to: coordinator)
    #expect(SharedStore.commandAck?.commandID == release.id)
    #expect(SharedStore.commandAck?.outcome == .notOwner)
    #expect(coordinator.inFlight?.id == dictation && coordinator.stopAccepted == nil)
    #expect(coordinator.phase == .recording && coordinator.lastCommandID != release.id)
    send(command(.cancel), to: coordinator)
    #expect(await until { coordinator.phase == .cancelled })
  }

  @Test("the watchdog releases a dictation whose owner's record went stale, on its tick, once, words kept")
  func watchdogReleases() async throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (coordinator, rig) = await listening()
    let dictation = try await recording(coordinator)
    // Older than the watchdog, and older than the presence window too, so no
    // keyboard is fresh enough to take the words: they go to the clipboard.
    onScreen(Self.keyboard, age: SharedStore.presenceWindow + 1)
    rig.clock.advance(by: DictationCoordinator.watchdogTick)
    #expect(await until { coordinator.watchdogReleased == dictation })
    #expect(rig.tasks.begun.filter { $0 == DictationCoordinator.releaseTask }.count == 1)
    #expect(await until { coordinator.phase == .noTarget })
    #expect(coordinator.inFlight == nil && coordinator.watchdog == nil)
    rig.clock.advance(by: DictationCoordinator.watchdogTick)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(rig.tasks.begun.filter { $0 == DictationCoordinator.releaseTask }.count == 1, "released once")
  }

  @Test("the watchdog stands down for a stop already accepted: the keyboard's own release is not doubled")
  func watchdogAfterAcceptedStop() async throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (coordinator, rig) = await listening()
    let dictation = try await recording(coordinator)
    send(command(.release), to: coordinator)
    #expect(SharedStore.commandAck?.outcome == .stopped(dictation))
    // Stale for the watchdog, still fresh enough to take the words.
    onScreen(Self.keyboard, age: BlurtShared.ownerWatchdog + 1)
    coordinator.tickWatchdog()
    rig.clock.advance(by: DictationCoordinator.watchdogTick)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(coordinator.watchdogReleased == nil)
    #expect(!rig.tasks.begun.contains(DictationCoordinator.releaseTask))
    let result = await takeResult()
    #expect(result?.recipient == Self.keyboard)
    #expect(await until { coordinator.phase == .pasted })
    #expect(coordinator.inFlight == nil && coordinator.watchdogReleased == nil)
  }

  @Test("a resend of an accepted press is re-acked started(d), with nothing started twice")
  func resend() async throws {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (coordinator, rig) = await listening()
    let press = command(.press)
    send(press, to: coordinator)
    let dictation = try #require(coordinator.inFlight?.id)
    #expect(await until { coordinator.phase == .recording })
    SharedStore.commandAck = nil
    send(press, to: coordinator)
    #expect(SharedStore.commandAck?.commandID == press.id)
    #expect(SharedStore.commandAck?.outcome == .started(dictation))
    #expect(coordinator.answered.count == 1 && coordinator.inFlight?.id == dictation)
    #expect(rig.source.started == 1)
    send(command(.cancel), to: coordinator)
    #expect(await until { coordinator.phase == .cancelled })
  }
}
