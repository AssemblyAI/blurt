import Foundation
import Synchronization
import Testing

@testable import BlurtiOSCore

@Suite("Shared defaults")
@MainActor
struct SharedDefaultsTests {
  /// How many signals each of two stores' observers heard.
  nonisolated private final class Heard: Sendable {
    let mine = Mutex(0)
    let theirs = Mutex(0)
  }

  /// This test's own App Group: a fresh scratch suite each test, since
  /// Swift Testing runs every test on a new instance of the suite.
  let store = SharedStore.scratch()

  @Test("a payload round-trips through the App Group; unreadable or removed is nothing")
  func payloads() {
    let result = DictationResult(id: UUID(), text: "hi", deliveredAt: Date(), recipient: "kb")
    store.write(result, forKey: BlurtShared.Key.result)
    #expect(store.read(DictationResult.self, forKey: BlurtShared.Key.result)?.id == result.id)
    store.defaults.set(Data("not json".utf8), forKey: BlurtShared.Key.result)
    #expect(store.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
    store.write(result, forKey: BlurtShared.Key.result)
    store.remove(forKey: BlurtShared.Key.result)
    #expect(store.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
  }

  @Test("each setting has its default until chosen, and keeps what was chosen")
  func settings() {
    #expect(!store.autoDictate)
    store.autoDictate = true
    #expect(store.autoDictate)
    #expect(store.windowMinutes == 15)
    // 0 is a real choice (until closed), not the unset default.
    store.windowMinutes = 0
    #expect(store.windowMinutes == 0)
    #expect(store.lexiconRefreshedAt == nil)
  }

  @Test("a scratch store is its own: another sees none of its records, and hears none of its signals")
  func scratchIsolated() async {
    let other = SharedStore.scratch()
    store.autoDictate = true
    #expect(!other.autoDictate)
    #expect(store.defaults !== other.defaults)
    #expect(SharedStore(defaults: store.defaults).signalPrefix.isEmpty, "`live`'s: the two processes' names as is")
    #expect(store.signalPrefix != other.signalPrefix && !store.signalPrefix.isEmpty)
    let heard = Heard()
    let mine = store.observe(BlurtShared.Signal.phase) { heard.mine.withLock { $0 += 1 } }
    let theirs = other.observe(BlurtShared.Signal.phase) { heard.theirs.withLock { $0 += 1 } }
    store.post(BlurtShared.Signal.phase)
    #expect(await until { heard.mine.withLock { $0 } == 1 })
    let theirsHeard = heard.theirs.withLock { $0 }
    #expect(theirsHeard == 0)
    withExtendedLifetime((mine, theirs)) {
      // Nothing to run: this only keeps both observers alive to here.
    }
  }

  @Test("a contact name has both sides equal; a text replacement does not")
  func lexiconEntries() {
    #expect(LexiconEntry(userInput: "Neil Bisht", documentText: "Neil Bisht").isName)
    #expect(!LexiconEntry(userInput: "omw", documentText: "On my way!").isName)
  }
}
