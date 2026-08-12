import Foundation
import Testing

@testable import BlurtEngine

@Suite("KeyTermsStore.parse")
struct KeyTermsStoreTests {
  @Test("nil and blank input yield no terms")
  func emptyInputs() {
    #expect(KeyTermsStore.parse(nil).isEmpty)
    #expect(KeyTermsStore.parse("").isEmpty)
    #expect(KeyTermsStore.parse("   ,  , \n").isEmpty)
  }

  @Test("comma-separated input splits and trims each term")
  func splitsAndTrims() {
    #expect(KeyTermsStore.parse("AssemblyAI, Kubernetes ,  Anthropic") == ["AssemblyAI", "Kubernetes", "Anthropic"])
  }

  @Test("blank entries between commas are dropped")
  func dropsBlanks() {
    #expect(KeyTermsStore.parse("foo,,bar, ,baz") == ["foo", "bar", "baz"])
  }

  @Test("duplicates are removed case-insensitively, keeping the first spelling")
  func dedupesCaseInsensitively() {
    #expect(KeyTermsStore.parse("Blurt, blurt, BLURT, Slack") == ["Blurt", "Slack"])
  }

  @Test("multi-word terms survive (only commas split)")
  func multiWordTerms() {
    #expect(KeyTermsStore.parse("San Francisco, New York") == ["San Francisco", "New York"])
  }
}

/// The read side, against an isolated defaults suite like every other store's
/// suite (`freshDefaults()`). Each case writes the defaults slot directly, which
/// is exactly how production writes it: the store has no setter, and the Settings
/// field's `@AppStorage` binding is the only writer. So these pin the contract
/// that matters — whatever raw text the field happens to hold, the read side
/// normalizes it.
@Suite("KeyTermsStore.raw")
struct KeyTermsStoreGetTests {
  /// A store over a throwaway suite holding `stored` (or nothing). Isolated per
  /// case, so this suite neither needs `.serialized` nor can leave the
  /// developer's own key terms changed — which the previous save-and-restore
  /// dance around `UserDefaults.standard` did whenever a case failed hard.
  private func makeStore(_ stored: String?) -> KeyTermsStore {
    let defaults = freshDefaults()
    if let stored { defaults.set(stored, forKey: KeyTermsStore.defaultsKey) }
    return KeyTermsStore(defaults: defaults)
  }

  @Test("raw trims the stored string; terms parses it")
  func rawAndTerms() {
    let store = makeStore("  AssemblyAI, Slack  ")
    #expect(store.raw == "AssemblyAI, Slack")
    #expect(store.terms == ["AssemblyAI", "Slack"])
  }

  @Test("an unset key reads as no terms")
  func unsetReadsAsNil() {
    let store = makeStore(nil)
    #expect(store.raw == nil)
    #expect(store.terms.isEmpty)
  }

  @Test("a blank field reads as no terms rather than an empty term", arguments: ["", "   \n"])
  func blankReadsAsNil(stored: String) {
    // The field is cleared by emptying it, not by deleting the key, so the slot
    // genuinely holds "" (or whitespace mid-edit). That must read as "no terms",
    // otherwise the prompt would carry an empty vocabulary clause.
    let store = makeStore(stored)
    #expect(store.raw == nil)
    #expect(store.terms.isEmpty)
  }

  @Test("each store reads its own defaults, so a stored list can't leak between them")
  func storesAreIndependent() {
    // The reason the store takes its `UserDefaults`: the pipeline's provider and
    // the Settings field must be able to read the same slot, while a test reads
    // one nobody else can see.
    #expect(makeStore("Blurt").terms == ["Blurt"])
    #expect(makeStore(nil).terms.isEmpty)
  }
}
