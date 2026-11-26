import Foundation
import Testing

@testable import BlurtEngine

/// The edits both apps' editors make to the stored style profiles and text
/// shortcuts: the save rule, the field caps, save-or-add by id, and remove.
@Suite("Settings list editing")
struct SettingsListEditingTests {
  @Test("a style needs both a name and instructions, blank of any whitespace counting as none")
  func styleCanSave() {
    #expect(StyleProfile.canSave(name: "Casual", instructions: "lowercase"))
    #expect(!StyleProfile.canSave(name: " \n", instructions: "lowercase"))
    #expect(!StyleProfile.canSave(name: "Casual", instructions: "\n\t "))
  }

  @Test("style fields clamp to the store's limits, whole graphemes only")
  func styleClamps() {
    let longName = String(repeating: "a", count: StyleProfileStore.nameLimit + 5)
    #expect(StyleProfileStore.clampedName(longName).count == StyleProfileStore.nameLimit)
    #expect(StyleProfileStore.clampedName("Casual") == "Casual")
    let emoji = String(repeating: "😀", count: StyleProfileStore.characterLimit)
    let clamped = StyleProfileStore.clampedInstructions(emoji)
    #expect(clamped.utf8.count <= StyleProfileStore.characterLimit)
    #expect(clamped.allSatisfy { $0 == "😀" })
  }

  @Test("saving a style replaces the one with its id in place, or adds it at the end; remove drops it")
  func styleSaveAndRemove() {
    let store = StyleProfileStore(defaults: freshDefaults())
    let first = StyleProfile(name: "One", instructions: "a")
    let second = StyleProfile(name: "Two", instructions: "b")
    store.save(first)
    store.save(second)
    var renamed = first
    renamed.name = "Uno"
    store.save(renamed)
    #expect(store.profiles.map(\.name) == ["Uno", "Two"])
    store.remove(id: first.id)
    #expect(store.profiles.map(\.id) == [second.id])
    store.remove(id: first.id)
    #expect(store.profiles.map(\.id) == [second.id])
  }

  @Test("shortcut fields clamp to the store's limits")
  func shortcutClamps() {
    let trigger = String(repeating: "a", count: TextShortcutStore.triggerLimit + 1)
    #expect(TextShortcutStore.clampedTrigger(trigger).count == TextShortcutStore.triggerLimit)
    let expansion = String(repeating: "b", count: TextShortcutStore.expansionLimit + 1)
    #expect(TextShortcutStore.clampedExpansion(expansion).count == TextShortcutStore.expansionLimit)
  }

  @Test("saving a shortcut replaces in place or appends, insertFirst leads, and remove drops it")
  func shortcutSaveInsertAndRemove() {
    let store = TextShortcutStore(defaults: freshDefaults())
    let email = TextShortcut(trigger: "personal email", expansion: "me@example.com")
    let phone = TextShortcut(trigger: "my phone", expansion: "555")
    store.save(email)
    store.insertFirst(phone)
    #expect(store.shortcuts.map(\.id) == [phone.id, email.id])
    var edited = email
    edited.expansion = "you@example.com"
    store.save(edited)
    #expect(store.shortcuts.map(\.expansion) == ["555", "you@example.com"])
    store.remove(id: phone.id)
    #expect(store.shortcuts.map(\.id) == [email.id])
  }
}
