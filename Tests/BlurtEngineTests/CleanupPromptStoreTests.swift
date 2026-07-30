import Foundation
import Testing

@testable import BlurtEngine

@Suite("CleanupPromptStore")
struct CleanupPromptStoreTests {
  @Test("reads nil when unset")
  func nilWhenUnset() {
    #expect(CleanupPromptStore(defaults: freshDefaults()).instruction == nil)
  }

  @Test("persists and reads back an instruction")
  func roundTrips() {
    let defaults = freshDefaults()
    let store = CleanupPromptStore(defaults: defaults)
    store.instruction = "Fix punctuation."
    #expect(CleanupPromptStore(defaults: defaults).instruction == "Fix punctuation.")
  }

  @Test("a blank instruction reads back as nil and removes the key")
  func blankIsNil() {
    let defaults = freshDefaults()
    let store = CleanupPromptStore(defaults: defaults)
    store.instruction = "Be terse."
    store.instruction = "   \n"
    #expect(CleanupPromptStore(defaults: defaults).instruction == nil)
    // Blank clears the slot entirely rather than persisting whitespace.
    #expect(defaults.object(forKey: CleanupPromptStore.defaultsKey) == nil)
  }

  @Test("the getter trims surrounding whitespace")
  func getterTrims() {
    let defaults = freshDefaults()
    defaults.set("  Be terse.  ", forKey: CleanupPromptStore.defaultsKey)
    #expect(CleanupPromptStore(defaults: defaults).instruction == "Be terse.")
  }

  @Test("the setter truncates to the character cap")
  func setterTruncates() {
    let defaults = freshDefaults()
    let store = CleanupPromptStore(defaults: defaults)
    store.instruction = String(repeating: "x", count: CleanupPromptStore.characterCap + 50)
    #expect(store.instruction?.count == CleanupPromptStore.characterCap)
  }
}
