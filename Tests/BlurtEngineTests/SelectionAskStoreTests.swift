import Foundation
import Testing

@testable import BlurtEngine

@Suite("SelectionAskStore")
struct SelectionAskStoreTests {
  @Test("defaults to off when unset — asking sends the selection to the LLM Gateway, so it is its own opt-in")
  func defaultsToOff() {
    #expect(!SelectionAskStore(defaults: freshDefaults()).isEnabled)
    #expect(!SelectionAskStore.defaultValue)
  }

  @Test("reads back the switch the Settings toggle writes")
  func readsBackTheToggledSlot() {
    let defaults = freshDefaults()
    let store = SelectionAskStore(defaults: defaults)
    defaults.set(false, forKey: SelectionAskStore.defaultsKey)
    #expect(!store.isEnabled)
    defaults.set(true, forKey: SelectionAskStore.defaultsKey)
    #expect(store.isEnabled)
  }
}
