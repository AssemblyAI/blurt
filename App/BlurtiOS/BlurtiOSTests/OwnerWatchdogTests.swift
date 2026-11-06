import Foundation
import Testing

@testable import BlurtiOSCore

/// The owner-based rule: a dictation lives while its own keyboard is on screen and recent.
@Suite("Owner watchdog")
struct OwnerWatchdogTests {
  private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
  private let owned = DictationRef(id: UUID(), ownerProcessID: "keyboard-owner")
  private let unowned = DictationRef(id: UUID(), ownerProcessID: nil)

  private func presence(_ processID: String = "keyboard-owner", onScreen: Bool = true, age: TimeInterval = 0)
    -> KeyboardPresenceRecord
  {
    KeyboardPresenceRecord(
      processID: processID, controllerID: "field", pid: 1, seenAt: now.addingTimeInterval(-age), onScreen: onScreen)
  }

  private func release(_ inFlight: DictationRef?, _ presence: KeyboardPresenceRecord?) -> Bool {
    OwnerWatchdog.shouldRelease(inFlight: inFlight, presence: presence, now: now)
  }

  @Test("nothing in flight, nothing to release, whatever the keyboard is doing")
  func nothingInFlight() {
    #expect(!release(nil, nil))
    #expect(!release(nil, presence()))
    #expect(!release(nil, presence(onScreen: false, age: 60)))
  }

  @Test("the owner on screen and recent keeps its dictation alive")
  func ownerPresent() {
    #expect(!release(owned, presence()))
    #expect(!release(owned, presence(age: BlurtShared.ownerWatchdog / 2)))
  }

  @Test("no presence record at all: the owner is gone")
  func noRecord() {
    #expect(release(owned, nil))
  }

  @Test("the owner's record saying it left is a release")
  func ownerLeft() {
    #expect(release(owned, presence(onScreen: false)))
  }

  @Test("the owner's record older than the watchdog is a release; at the watchdog exactly it still counts")
  func boundary() {
    #expect(!release(owned, presence(age: BlurtShared.ownerWatchdog)))
    #expect(release(owned, presence(age: BlurtShared.ownerWatchdog + 0.001)))
    #expect(release(owned, presence(age: BlurtShared.ownerWatchdog * 2)))
  }

  @Test("another keyboard on screen does not keep the owner's dictation alive: the rule is owner-based")
  func otherKeyboardOnScreen() {
    #expect(release(owned, presence("keyboard-other")))
    #expect(release(owned, presence("keyboard-other", onScreen: false)))
  }

  @Test("a dictation nobody owns is kept alive by whoever is on screen, and released once nobody is")
  func unownedDictation() {
    #expect(!release(unowned, presence("keyboard-other")))
    #expect(release(unowned, presence("keyboard-other", onScreen: false)))
    #expect(release(unowned, presence("keyboard-other", age: BlurtShared.ownerWatchdog + 1)))
    #expect(release(unowned, nil))
  }

  @Test("the watchdog outlasts two keyboard beats")
  func watchdogRatio() {
    #expect(BlurtShared.ownerWatchdog > 2 * SharedStore.keyboardHeartbeatInterval)
  }
}
