import Foundation
import Testing

@testable import BlurtEngine

@Suite("TextShortcutStore")
struct TextShortcutStoreTests {
  @Test("an untouched install has no shortcuts")
  func unsetIsEmpty() {
    #expect(TextShortcutStore(defaults: freshDefaults()).shortcuts.isEmpty)
  }

  @Test("shortcuts round-trip through defaults, in order")
  func roundTrip() {
    let store = TextShortcutStore(defaults: freshDefaults())
    let written = [
      TextShortcut(trigger: "personal email", expansion: "me@example.com"),
      TextShortcut(trigger: "personal github", expansion: "https://github.com/me"),
    ]
    store.shortcuts = written
    #expect(store.shortcuts == written)
  }

  @Test("normalization trims, drops blanks, and dedupes triggers case-insensitively")
  func normalization() {
    let store = TextShortcutStore(defaults: freshDefaults())
    store.shortcuts = [
      TextShortcut(trigger: "  personal email ", expansion: " me@example.com\n"),
      TextShortcut(trigger: "Personal Email", expansion: "other@example.com"),
      TextShortcut(trigger: "   ", expansion: "orphan"),
      TextShortcut(trigger: "empty", expansion: "  "),
    ]
    #expect(store.shortcuts.map(\.trigger) == ["personal email"])
    #expect(store.shortcuts.map(\.expansion) == ["me@example.com"])
  }

  /// The expander can't tell these apart, so keeping both would leave one of
  /// them silently unreachable.
  @Test("dedupe treats triggers that differ only in separators as one phrase")
  func dedupeBySeparatorlessKey() {
    let store = TextShortcutStore(defaults: freshDefaults())
    store.shortcuts = [
      TextShortcut(trigger: "personal email", expansion: "a@example.com"),
      TextShortcut(trigger: "Personal-Email", expansion: "b@example.com"),
      TextShortcut(trigger: "personalemail", expansion: "c@example.com"),
      TextShortcut(trigger: "...", expansion: "unmatchable"),
    ]
    #expect(store.shortcuts.map(\.expansion) == ["a@example.com"])
    #expect(TextShortcut.matchKey(for: "Cal.com") == TextShortcut.matchKey(for: "cal com"))
  }

  @Test("an undecodable slot reads as no shortcuts")
  func corrupt() {
    let defaults = freshDefaults()
    defaults.set("not json", forKey: TextShortcutStore.defaultsKey)
    #expect(TextShortcutStore(defaults: defaults).shortcuts.isEmpty)
  }
}
