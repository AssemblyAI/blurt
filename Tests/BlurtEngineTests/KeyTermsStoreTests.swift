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

/// `get`/`set` round-trip through `UserDefaults.standard`, so this suite is
/// serialized and saves/restores the real key around each case — it must not
/// leave the dev machine's stored terms changed.
@Suite("KeyTermsStore.get/set", .serialized)
struct KeyTermsStoreGetSetTests {
  private func withCleanStore(_ body: () -> Void) {
    let key = KeyTermsStore.defaultsKey
    let original = UserDefaults.standard.string(forKey: key)
    defer {
      if let original {
        UserDefaults.standard.set(original, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
    body()
  }

  @Test("set stores the trimmed string; get and terms round-trip it")
  func setAndGet() {
    withCleanStore {
      KeyTermsStore.set("  AssemblyAI, Slack  ")
      #expect(KeyTermsStore.get() == "AssemblyAI, Slack")
      #expect(KeyTermsStore.terms() == ["AssemblyAI", "Slack"])
    }
  }

  @Test("set(nil) clears the stored value")
  func setNilClears() {
    withCleanStore {
      KeyTermsStore.set("Kubernetes")
      KeyTermsStore.set(nil)
      #expect(KeyTermsStore.get() == nil)
    }
  }

  @Test("set with a blank string clears the stored value")
  func setBlankClears() {
    withCleanStore {
      KeyTermsStore.set("Kubernetes")
      KeyTermsStore.set("   \n")
      #expect(KeyTermsStore.get() == nil)
    }
  }
}
