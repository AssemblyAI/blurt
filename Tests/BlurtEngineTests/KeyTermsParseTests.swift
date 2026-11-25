import Testing

@testable import AssemblyAI
@testable import BlurtEngine

@Suite("KeyTermList.parse")
struct KeyTermsParseTests {
  @Test("nil and blank input yield no terms")
  func emptyInputs() {
    #expect(KeyTermList.parse(nil).isEmpty)
    #expect(KeyTermList.parse("").isEmpty)
    #expect(KeyTermList.parse("   ,  , \n").isEmpty)
  }

  @Test("comma-separated input splits and trims each term")
  func splitsAndTrims() {
    #expect(KeyTermList.parse("AssemblyAI, Kubernetes ,  Anthropic") == ["AssemblyAI", "Kubernetes", "Anthropic"])
  }

  @Test("blank entries between commas are dropped")
  func dropsBlanks() {
    #expect(KeyTermList.parse("foo,,bar, ,baz") == ["foo", "bar", "baz"])
  }

  @Test("duplicates are removed case-insensitively, keeping the first spelling")
  func dedupesCaseInsensitively() {
    #expect(KeyTermList.parse("Blurt, blurt, BLURT, Slack") == ["Blurt", "Slack"])
  }

  @Test("multi-word terms survive (only commas split)")
  func multiWordTerms() {
    #expect(KeyTermList.parse("San Francisco, New York") == ["San Francisco", "New York"])
  }

  @Test("join is what parse reads back")
  func joinRoundTrips() {
    let terms = ["AssemblyAI", "San Francisco", "LeMUR"]
    #expect(KeyTermList.join(terms) == "AssemblyAI, San Francisco, LeMUR")
    #expect(KeyTermList.parse(KeyTermList.join(terms)) == terms)
  }

  @Test("normalized cleans a list without splitting its terms on commas")
  func normalizedKeepsCommas() {
    // A contact called "Smith, John" is one name; the iPhone app merges such
    // names with the user's terms through this rather than through `parse`.
    #expect(KeyTermList.normalized([" Smith, John ", "", "smith, john", "Blurt"]) == ["Smith, John", "Blurt"])
  }
}
