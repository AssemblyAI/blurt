import Foundation
import Testing

@testable import BlurtEngine

@Suite("SelectionSpeechStore")
struct SelectionSpeechStoreTests {
  @Test("defaults to off when unset — the feature is experimental opt-in")
  func defaultsToOff() {
    #expect(!SelectionSpeechStore(defaults: freshDefaults()).isEnabled)
  }

  @Test("reads back the switch the Settings toggle writes")
  func readsBackTheToggledSlot() {
    let defaults = freshDefaults()
    let store = SelectionSpeechStore(defaults: defaults)
    defaults.set(true, forKey: SelectionSpeechStore.defaultsKey)
    #expect(store.isEnabled)
    defaults.set(false, forKey: SelectionSpeechStore.defaultsKey)
    #expect(!store.isEnabled)
  }
}
