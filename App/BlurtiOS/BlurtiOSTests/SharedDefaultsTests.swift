import Foundation
import Testing

@testable import BlurtiOSCore

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
