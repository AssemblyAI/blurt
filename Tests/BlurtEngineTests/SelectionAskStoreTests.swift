import Foundation
import Testing

@testable import BlurtEngine

@Suite("SelectionAskStore")
struct SelectionAskStoreTests {
  @Test("defaults to on when unset — it only acts once read-aloud is opted in to")
  func defaultsToOn() {
    #expect(SelectionAskStore(defaults: freshDefaults()).isEnabled)
    #expect(SelectionAskStore.defaultValue)
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
