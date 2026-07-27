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

/// `get`/`terms` read `UserDefaults.standard`, so this suite is serialized and
/// saves/restores the real key around each case — it must not leave the dev
/// machine's stored terms changed.
///
/// Each case writes the defaults slot directly, which is exactly how production
/// writes it: the store has no setter, and the Settings field's `@AppStorage`
/// binding is the only writer. So these pin the contract that matters — whatever
/// raw text the field happens to hold, the read side normalizes it.
@Suite("KeyTermsStore.raw", .serialized)
struct KeyTermsStoreGetTests {
  private func withCleanStore(_ stored: String?, _ body: () -> Void) {
    let key = KeyTermsStore.defaultsKey
    let original = UserDefaults.standard.string(forKey: key)
    defer {
      if let original {
        UserDefaults.standard.set(original, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
    if let stored {
      UserDefaults.standard.set(stored, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
    body()
  }

  @Test("get trims the stored string; terms parses it")
  func getAndTerms() {
    withCleanStore("  AssemblyAI, Slack  ") {
      #expect(KeyTermsStore.raw == "AssemblyAI, Slack")
      #expect(KeyTermsStore.terms == ["AssemblyAI", "Slack"])
    }
  }

  @Test("an unset key reads as no terms")
  func unsetReadsAsNil() {
    withCleanStore(nil) {
      #expect(KeyTermsStore.raw == nil)
      #expect(KeyTermsStore.terms.isEmpty)
    }
  }

  @Test("a blank field reads as no terms rather than an empty term")
  func blankReadsAsNil() {
    // The field is cleared by emptying it, not by deleting the key, so the slot
    // genuinely holds "" (or whitespace mid-edit). That must read as "no terms",
    // otherwise the prompt would carry an empty vocabulary clause.
    withCleanStore("   \n") {
      #expect(KeyTermsStore.raw == nil)
      #expect(KeyTermsStore.terms.isEmpty)
    }
    withCleanStore("") {
      #expect(KeyTermsStore.raw == nil)
      #expect(KeyTermsStore.terms.isEmpty)
    }
  }
}
