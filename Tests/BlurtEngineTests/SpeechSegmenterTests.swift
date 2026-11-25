import Testing

@testable import AssemblyAI

@Suite("SpeechSegmenter")
struct SpeechSegmenterTests {
  /// One `segments(of:)` expectation at the default length cap.
  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    let text: String
    let expected: [String]
    var testDescription: String { name }
  }

  static let cases: [Case] = [
    Case(
      name: "cuts at sentence ends, keeping the punctuation",
      text: "It works. Does it? Yes it does!",
      expected: ["It works.", "Does it?", "Yes it does!"]
    ),
    Case(
      name: "a closing curly quote still ends the sentence",
      text: "She said “you uploaded me.” The clock ticks.",
      expected: ["She said “you uploaded me.”", "The clock ticks."]
    ),
    Case(
      name: "decimals and versions are not sentence ends",
      text: "Pi is 3.14 in v1.2 today.",
      expected: ["Pi is 3.14 in v1.2 today."]
    ),
    Case(
      name: "one-word sentences join the next — abbreviations don't flush alone",
      text: "Dr. Smith is in. Go.",
      expected: ["Dr. Smith is in. Go."]
    ),
    Case(
      name: "a short trailing sentence joins the previous one",
      text: "That went well. Thanks.",
      expected: ["That went well. Thanks."]
    ),
    Case(name: "a lone short sentence is its own segment", text: "Hi.", expected: ["Hi."]),
    Case(
      name: "line breaks end a segment even without punctuation",
      text: "Release notes here\n\nFixed the paste bug",
      expected: ["Release notes here", "Fixed the paste bug"]
    ),
    Case(name: "blank input yields nothing to send", text: "  \n ", expected: []),
  ]

  @Test("segments cuts text into speakable sentences", arguments: cases)
  func segments(_ c: Case) {
    #expect(SpeechSegmenter.segments(of: c.text) == c.expected)
  }

  @Test("a runaway sentence splits at whitespace under the cap")
  func runaway() {
    let pieces = SpeechSegmenter.segments(of: "alpha beta gamma delta epsilon", maxCharacters: 12)
    #expect(pieces == ["alpha beta", "gamma delta", "epsilon"])
    #expect(pieces.allSatisfy { $0.count <= 12 })
  }

  @Test("a run with no whitespace is cut hard at the cap")
  func hardCut() {
    #expect(SpeechSegmenter.split("abcdefghij", maxCharacters: 4) == ["abcd", "efgh", "ij"])
  }
}
