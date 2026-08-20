import Foundation
import Testing

@testable import BlurtEngine

/// Both sides, against an isolated defaults suite like every other store's. This
/// store *does* write (the JSON shape is its business — see the type's note on
/// the encoded-value exception), so each case drives the setter rather than
/// poking the slot, except where the point is what an untouched or pre-profiles
/// install reads back as. The combination with the base cleanup instruction stays
/// `CleanupInstructionTests`' job, and the budget these caps re-export is pinned
/// there (`customStyleBudgetIsTheHeadroom`).
@Suite("StyleProfileStore")
struct StyleProfileStoreTests {
  private func makeStore() -> StyleProfileStore {
    StyleProfileStore(defaults: freshDefaults())
  }

  /// A store whose defaults hold only the pre-profiles single field, which is
  /// exactly what an install that never saw this feature looks like.
  private func makeLegacyStore(_ legacy: String) -> StyleProfileStore {
    let defaults = freshDefaults()
    defaults.set(legacy, forKey: StyleProfileStore.legacyDefaultsKey)
    return StyleProfileStore(defaults: defaults)
  }

  @Test("an untouched install has no profiles and sends no instructions")
  func unsetIsEmpty() {
    let store = makeStore()
    #expect(store.profiles.isEmpty)
    #expect(store.active == nil)
    #expect(store.activeInstructions == nil)
  }

  /// The whole reason this store owns the encoding: ids, names, text and order
  /// all have to survive the JSON round trip, or a rename would deactivate a
  /// profile and a reorder would move the buttons.
  @Test("profiles round-trip through defaults, in order")
  func profilesRoundTrip() {
    let store = makeStore()
    let written = [
      StyleProfile(name: "Casual", instructions: "keep it breezy"),
      StyleProfile(name: "Formal", instructions: "no contractions"),
    ]
    store.profiles = written
    #expect(store.profiles == written)
  }

  /// The read-side migration. No list plus a non-blank legacy field reads as one
  /// active profile named "Custom" holding that text — with a *fixed* id, so two
  /// reads name the same profile.
  @Test("the legacy field reads as one active profile named Custom")
  func legacyFieldMigratesOnRead() throws {
    let store = makeLegacyStore("  always write in lowercase \n")
    let profile = try #require(store.profiles.first)
    #expect(store.profiles.count == 1)
    #expect(profile.name == StyleProfileStore.legacyProfileName)
    #expect(profile.id == StyleProfileStore.legacyProfileID)
    #expect(profile.instructions == "always write in lowercase")
    #expect(store.active == profile)
    #expect(store.activeInstructions == "always write in lowercase")
  }

  /// A cleared or space-padded legacy field must not conjure an empty profile —
  /// it means "this user never set a style", same as an absent key.
  @Test("a blank legacy field migrates nothing", arguments: ["", "   \n "])
  func blankLegacyFieldMigratesNothing(legacy: String) {
    #expect(makeLegacyStore(legacy).profiles.isEmpty)
  }

  /// Once a list exists it is the whole answer, including when it is empty:
  /// deleting every profile must not resurrect text the user last saw years ago.
  @Test("a stored list shadows the legacy field, even when empty")
  func storedListShadowsLegacy() {
    let defaults = freshDefaults()
    defaults.set("always write in lowercase", forKey: StyleProfileStore.legacyDefaultsKey)
    let store = StyleProfileStore(defaults: defaults)
    store.profiles = []
    #expect(store.profiles.isEmpty)
    #expect(store.activeInstructions == nil)
  }

  @Test("writing more than the limit keeps the first profiles")
  func writeTrimsToTheProfileLimit() {
    let store = makeStore()
    store.profiles = (1...StyleProfileStore.profileLimit + 3).map {
      StyleProfile(name: "Style \($0)", instructions: "instruction \($0)")
    }
    #expect(store.profiles.count == StyleProfileStore.profileLimit)
    #expect(store.profiles.last?.name == "Style \(StyleProfileStore.profileLimit)")
  }

  /// The cap is per profile because only one profile is ever sent. Both are
  /// trimmed to the full budget even though their sum is far over it — a sum that
  /// would matter only if they were concatenated, which is precisely what this
  /// store must never do.
  @Test("each profile's instructions are trimmed to the byte budget")
  func writeTrimsEachInstructionToTheBudget() {
    let store = makeStore()
    let oversized = String(repeating: "x", count: StyleProfileStore.characterLimit + 100)
    store.profiles = [
      StyleProfile(name: "One", instructions: oversized),
      StyleProfile(name: "Two", instructions: oversized),
    ]
    for profile in store.profiles {
      #expect(profile.instructions.utf8.count == StyleProfileStore.characterLimit)
    }
  }

  /// Names bound the main window's fixed-width buttons, and a nameless profile
  /// would render a button with nothing on it.
  @Test("names are trimmed to the name limit and never left blank")
  func writeNormalizesNames() {
    let store = makeStore()
    store.profiles = [
      StyleProfile(
        name: String(repeating: "n", count: StyleProfileStore.nameLimit + 10), instructions: "a"),
      StyleProfile(name: "   ", instructions: "b"),
    ]
    #expect(store.profiles.first?.name.count == StyleProfileStore.nameLimit)
    #expect(store.profiles.last?.name == StyleProfileStore.fallbackName)
  }

  /// The load-bearing one: the request carries the active profile's text and
  /// nothing else. A join of all three would exceed the API's instruction cap and
  /// 400 the whole dictation.
  @Test("only the active profile's instructions are returned")
  func onlyTheActiveProfileIsSent() throws {
    let store = makeStore()
    let profiles = [
      StyleProfile(name: "Casual", instructions: "keep it breezy"),
      StyleProfile(name: "Formal", instructions: "no contractions"),
      StyleProfile(name: "Terse", instructions: "cut every adjective"),
    ]
    store.profiles = profiles
    store.activate(profiles[1])

    #expect(store.active == profiles[1])
    let sent = try #require(store.activeInstructions)
    #expect(sent == "no contractions")
    #expect(!sent.contains("keep it breezy"))
    #expect(!sent.contains("cut every adjective"))
  }

  /// A style stays selected until the user picks another — nothing snaps it back
  /// — and the pointer survives an unrelated edit to the list.
  @Test("the active choice is sticky across a list edit")
  func activeChoiceIsSticky() {
    let store = makeStore()
    let profiles = [
      StyleProfile(name: "Casual", instructions: "keep it breezy"),
      StyleProfile(name: "Formal", instructions: "no contractions"),
    ]
    store.profiles = profiles
    store.activate(profiles[1])
    store.profiles = profiles + [StyleProfile(name: "Terse", instructions: "cut adjectives")]
    #expect(store.activeInstructions == "no contractions")
  }

  /// Never chosen, or naming a profile the user has since deleted: fall back to
  /// the first defined one rather than silently sending no style at all.
  @Test("an unset or stale active pointer falls back to the first profile")
  func activeFallsBackToTheFirstProfile() {
    let store = makeStore()
    let profiles = [
      StyleProfile(name: "Casual", instructions: "keep it breezy"),
      StyleProfile(name: "Formal", instructions: "no contractions"),
    ]
    store.profiles = profiles
    // Nothing chosen yet.
    #expect(store.activeInstructions == "keep it breezy")
    // Chosen, then deleted out from under the pointer.
    store.activate(profiles[1])
    store.profiles = [profiles[0]]
    #expect(store.activeInstructions == "keep it breezy")
  }

  /// Blank text in the active profile means "send the base instruction
  /// untouched", not an empty suffix — the same rule the single field had.
  @Test("blank instructions in the active profile send nothing", arguments: ["", "  \n "])
  func blankActiveInstructionsSendNothing(instructions: String) {
    let store = makeStore()
    store.profiles = [StyleProfile(name: "Empty", instructions: instructions)]
    #expect(store.activeInstructions == nil)
  }

  /// A stored value that will not decode reads as no profiles. Deliberately not
  /// the legacy fallback: a list exists, so reviving the pre-profiles text would
  /// be a surprising resurrection rather than a migration.
  @Test("an undecodable stored list reads as no profiles")
  func corruptStoredListReadsAsEmpty() {
    let defaults = freshDefaults()
    defaults.set("not json", forKey: StyleProfileStore.defaultsKey)
    defaults.set("always write in lowercase", forKey: StyleProfileStore.legacyDefaultsKey)
    #expect(StyleProfileStore(defaults: defaults).profiles.isEmpty)
  }
}
