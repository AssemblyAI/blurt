import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// `KeyTerms.fitted` is the last thing between the user's Settings list and
/// `config.keyterms_prompt`. The list is the one unbounded input in the request,
/// and over the field's cap the API rejects the whole request — so what these
/// pin is that an over-long list degrades to fewer terms rather than to a failed
/// dictation.
@Suite("KeyTerms")
struct KeyTermsTests {
  @Test("no terms sends no field")
  func emptyListSendsNothing() {
    // Empty is the one "nothing to send" state, which the encoders turn into an
    // absent `keyterms_prompt` rather than a `[]` asking to boost nothing.
    #expect(KeyTerms.fitted([]).isEmpty)
  }

  @Test("an all-blank list sends no field")
  func blankTermsSendNothing() {
    #expect(KeyTerms.fitted(["", "   ", "\n\t"]).isEmpty)
  }

  @Test("terms pass through trimmed, in the user's order")
  func termsPassThroughInOrder() {
    // Order is the user's — it decides which terms survive a list too long to
    // send — and the API takes the strings as spellings, so they arrive trimmed.
    #expect(KeyTerms.fitted(["AssemblyAI", " LeMUR ", "Blurt"]) == ["AssemblyAI", "LeMUR", "Blurt"])
  }

  @Test("blank entries are dropped from among real terms")
  func blanksDroppedAmongRealTerms() {
    // A stray comma in the Settings field must cost the request nothing.
    #expect(KeyTerms.fitted(["AssemblyAI", "  ", "LeMUR"]) == ["AssemblyAI", "LeMUR"])
  }

  @Test("an oversized list is fitted to the cap, keeping whole leading terms")
  func oversizedListIsFitted() {
    let terms = (0..<2000).map { "term\($0)" }
    let fitted = KeyTerms.fitted(terms)
    #expect(fitted.reduce(0) { $0 + $1.utf8.count } <= KeyTerms.characterCap)
    #expect(fitted.first == "term0")
    #expect(fitted.count < terms.count)
    // Whole terms only — a truncated name boosts nothing, so every survivor is
    // exactly what the user typed.
    #expect(fitted.allSatisfy { terms.contains($0) })
  }

  @Test("a single term larger than the cap sends no field at all")
  func oneHugeTermSendsNothing() {
    // Not a clipped fragment: half a name is not the term the user asked to
    // boost, so the field is dropped whole.
    #expect(KeyTerms.fitted([String(repeating: "k", count: KeyTerms.characterCap + 1)]).isEmpty)
  }

  @Test("a term that doesn't fit stops the list without dropping earlier ones")
  func overflowingTermStopsTheList() {
    let huge = String(repeating: "k", count: KeyTerms.characterCap)
    #expect(KeyTerms.fitted(["Blurt", huge, "LeMUR"]) == ["Blurt"])
  }

  @Test("a list under the byte cap is still cut to the documented term cap")
  func termCountIsCappedIndependently() {
    // The reachable one, and the reason `termCap` exists: 150 four-byte terms
    // total 600 bytes, nowhere near `characterCap`, yet `keyterms_prompt` takes
    // at most 100 items and 400s the whole request above that — so every
    // dictation would fail until the user shortened the field.
    let terms = (0..<150).map { "t\($0)" }
    let fitted = KeyTerms.fitted(terms)
    #expect(terms.reduce(0) { $0 + $1.utf8.count } < KeyTerms.characterCap)
    #expect(fitted.count == KeyTerms.termCap)
    // The user's order, first-typed wins — same rule as the byte cap.
    #expect(fitted.first == "t0")
    #expect(fitted.last == "t99")
  }

  @Test("a list at exactly the term cap is sent whole")
  func termCapBoundaryIsInclusive() {
    // Off-by-one guard on the boundary itself: 100 is allowed, 101 is not.
    #expect(KeyTerms.fitted((0..<100).map { "t\($0)" }).count == 100)
    #expect(KeyTerms.fitted((0..<101).map { "t\($0)" }).count == 100)
  }

  @Test("the boost cap is its own number, not the conversation context's")
  func capIsDistinctFromTheContextCap() {
    // Two caps on two fields of one request. Borrowing the other field's figure
    // is how an over-cap value shipped once before, so pin them apart.
    #expect(KeyTerms.characterCap == 2048)
    #expect(KeyTerms.characterCap != STTPrompt.characterCap)
    // And the term cap is a count, not a size — pinned so the two caps on this
    // one field can't be conflated either.
    #expect(KeyTerms.termCap == 100)
  }
}

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
}
