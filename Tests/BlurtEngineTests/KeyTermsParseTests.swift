import Testing

@testable import AssemblyAI
@testable import BlurtEngine

@Suite("KeyTerms.parse")
struct KeyTermsParseTests {
  @Test("nil and blank input yield no terms")
  func emptyInputs() {
    #expect(KeyTerms.parse(nil).isEmpty)
    #expect(KeyTerms.parse("").isEmpty)
    #expect(KeyTerms.parse("   ,  , \n").isEmpty)
  }

  @Test("comma-separated input splits and trims each term")
  func splitsAndTrims() {
    #expect(KeyTerms.parse("AssemblyAI, Kubernetes ,  Anthropic") == ["AssemblyAI", "Kubernetes", "Anthropic"])
  }

  @Test("blank entries between commas are dropped")
  func dropsBlanks() {
    #expect(KeyTerms.parse("foo,,bar, ,baz") == ["foo", "bar", "baz"])
  }

  @Test("duplicates are removed case-insensitively, keeping the first spelling")
  func dedupesCaseInsensitively() {
    #expect(KeyTerms.parse("Blurt, blurt, BLURT, Slack") == ["Blurt", "Slack"])
  }

  @Test("multi-word terms survive (only commas split)")
  func multiWordTerms() {
    #expect(KeyTerms.parse("San Francisco, New York") == ["San Francisco", "New York"])
  }

  @Test("join is what parse reads back")
  func joinRoundTrips() {
    let terms = ["AssemblyAI", "San Francisco", "LeMUR"]
    #expect(KeyTerms.join(terms) == "AssemblyAI, San Francisco, LeMUR")
    #expect(KeyTerms.parse(KeyTerms.join(terms)) == terms)
  }

  @Test("normalized cleans a list without splitting its terms on commas")
  func normalizedKeepsCommas() {
    // A contact called "Smith, John" is one name; the iPhone app merges such
    // names with the user's terms through this rather than through `parse`.
    #expect(KeyTerms.normalized([" Smith, John ", "", "smith, john", "Blurt"]) == ["Smith, John", "Blurt"])
  }
}
