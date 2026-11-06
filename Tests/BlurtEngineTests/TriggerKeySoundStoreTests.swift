import Foundation
import Testing

@testable import BlurtEngine

/// Each trigger key's own cue voice (`TriggerKeySoundStore`): absent until set,
/// per key, and removable back to "follow the action's setting".
@Suite("TriggerKeySoundStore")
struct TriggerKeySoundStoreTests {
  private let defaults = freshDefaults()
  private var store: TriggerKeySoundStore { TriggerKeySoundStore(defaults: defaults) }

  @Test("an untouched install stores nothing, so every key follows its action")
  func untouched() {
    #expect(defaults.string(forKey: TriggerKeySoundStore.defaultsKey) == nil)
    for key in TriggerKey.allCases { #expect(store.soundID(for: key) == nil) }
  }

  @Test("a key's voice is its own and sticks")
  func perKey() {
    store.setSoundID("juno-0", for: .leftOption)
    store.setSoundID("none", for: .rightCommand)
    #expect(store.soundID(for: .leftOption) == "juno-0")
    #expect(store.soundID(for: .rightCommand) == "none")
    #expect(store.soundID(for: .leftControl) == nil)
    let raw = defaults.string(forKey: TriggerKeySoundStore.defaultsKey) ?? ""
    #expect(TriggerKeySoundStore.soundIDs(decoding: raw) == [.leftOption: "juno-0", .rightCommand: "none"])
  }

  @Test("clearing a key's voice removes only its entry")
  func clear() {
    store.setSoundID("juno-0", for: .leftOption)
    store.setSoundID("rom1a-7", for: .leftControl)
    store.setSoundID(nil, for: .leftOption)
    #expect(store.soundID(for: .leftOption) == nil)
    #expect(store.soundID(for: .leftControl) == "rom1a-7")
  }
}
