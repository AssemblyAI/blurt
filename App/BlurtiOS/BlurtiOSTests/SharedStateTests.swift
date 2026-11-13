import Foundation
import Testing

@testable import BlurtiOSCore

@Suite("Phase snapshot staleness")
struct PhaseSnapshotTests {
  private func snapshot(_ state: PhaseSnapshot.State, ageSeconds: TimeInterval) -> PhaseSnapshot {
    PhaseSnapshot(state: state, message: nil, level: 0, at: Date().addingTimeInterval(-ageSeconds))
  }

  @Test("idle is never stale")
  func idle() {
    #expect(!snapshot(.idle, ageSeconds: 100_000).isStale)
  }

  @Test("a notice is over after three seconds")
  func notices() {
    for state in [PhaseSnapshot.State.pasted, .copied, .error] {
      #expect(!snapshot(state, ageSeconds: 2).isStale)
      #expect(snapshot(state, ageSeconds: 4).isStale)
    }
  }

  @Test("an in-flight state outlives no dictation past 1210 seconds")
  func inFlight() {
    for state in [PhaseSnapshot.State.connecting, .recording, .processing] {
      #expect(!snapshot(state, ageSeconds: 1200).isStale)
      #expect(snapshot(state, ageSeconds: 1211).isStale)
    }
  }

  @Test("the dwell matches the design: 1.2 s pasted, 2 s copied and error, none otherwise")
  func dwell() {
    #expect(snapshot(.pasted, ageSeconds: 0).noticeDwellSeconds == 1.2)
    #expect(snapshot(.copied, ageSeconds: 0).noticeDwellSeconds == 2)
    #expect(snapshot(.error, ageSeconds: 0).noticeDwellSeconds == 2)
    #expect(snapshot(.recording, ageSeconds: 0).noticeDwellSeconds == nil)
  }
}

@Suite("Shared defaults")
@MainActor
struct SharedDefaultsTests {
  @Test("a payload round-trips through the App Group; unreadable or removed is nothing")
  func payloads() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let result = DictationResult(id: UUID(), text: "hi", deliveredAt: Date(), recipient: "kb")
    SharedStore.write(result, forKey: BlurtShared.Key.result)
    #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result)?.id == result.id)
    SharedStore.defaults.set(Data("not json".utf8), forKey: BlurtShared.Key.result)
    #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
    SharedStore.write(result, forKey: BlurtShared.Key.result)
    SharedStore.remove(forKey: BlurtShared.Key.result)
    #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
  }

  @Test("each setting has its default until chosen, and keeps what was chosen")
  func settings() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    #expect(!SharedStore.autoDictate)
    SharedStore.autoDictate = true
    #expect(SharedStore.autoDictate)
    #expect(SharedStore.windowMinutes == 15)
    // 0 is a real choice (until closed), not the unset default.
    SharedStore.windowMinutes = 0
    #expect(SharedStore.windowMinutes == 0)
    #expect(SharedStore.lexiconRefreshedAt == nil)
  }

  @Test("a contact name has both sides equal; a text replacement does not")
  func lexiconEntries() {
    #expect(LexiconEntry(userInput: "Neil Bisht", documentText: "Neil Bisht").isName)
    #expect(!LexiconEntry(userInput: "omw", documentText: "On my way!").isName)
  }
}
