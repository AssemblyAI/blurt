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

  @Test("contains matches a trimmed term case-insensitively, and a blank term is in no list")
  func containsIgnoresCase() {
    #expect(KeyTermList.contains(" rizz ", in: ["Rizz"]))
    #expect(!KeyTermList.contains("Riz", in: ["Rizz"]))
    #expect(!KeyTermList.contains("  ", in: ["Rizz"]))
  }

  @Test("appending adds the draft's terms, splitting on commas and dropping duplicates of any case")
  func appendingAddsTerms() {
    #expect(KeyTermList.appending("Neil Bisht, blurt", to: ["Blurt"]) == ["Blurt", "Neil Bisht"])
    #expect(KeyTermList.appending("  ", to: ["Blurt"]) == ["Blurt"])
  }

  @Test("appending stops at maxCount, so nothing is kept that couldn't be sent")
  func appendingStopsAtTheCap() {
    let full = (0..<KeyTerms.termCap).map { "t\($0)" }
    #expect(KeyTermList.appending("one more", to: full, maxCount: KeyTerms.termCap) == full)
    let nearlyFull = Array(full.dropLast())
    #expect(KeyTermList.appending("one, two", to: nearlyFull, maxCount: KeyTerms.termCap) == nearlyFull + ["one"])
  }

  /// The iPhone keyboard's + and a shared list add without the cap, so the
  /// list can be over it; a typed add then used to cut the list back to the
  /// cap, deleting the rest.
  @Test("appending to a list already over maxCount keeps every term it had and adds nothing")
  func appendingOverTheCapKeepsTheList() {
    let over = (0..<(KeyTerms.termCap + 5)).map { "t\($0)" }
    #expect(KeyTermList.appending("one more", to: over, maxCount: KeyTerms.termCap) == over)
    #expect(KeyTermList.appending("t3", to: over, maxCount: KeyTerms.termCap) == over)
  }
}
