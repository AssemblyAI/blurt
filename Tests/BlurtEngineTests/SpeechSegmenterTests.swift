import Testing

@testable import BlurtEngine

@Suite("SpeechSegmenter")
struct SpeechSegmenterTests {
  @Test("cuts at sentence ends, keeping the punctuation")
  func sentences() {
    #expect(
      SpeechSegmenter.segments(of: "It works. Does it? Yes it does!")
        == ["It works.", "Does it?", "Yes it does!"])
  }

  @Test("a closing curly quote still ends the sentence")
  func curlyCloser() {
    #expect(
      SpeechSegmenter.segments(of: "She said “you uploaded me.” The clock ticks.")
        == ["She said “you uploaded me.”", "The clock ticks."])
  }

  @Test("decimals and versions are not sentence ends")
  func decimals() {
    #expect(SpeechSegmenter.segments(of: "Pi is 3.14 in v1.2 today.") == ["Pi is 3.14 in v1.2 today."])
  }

  @Test("one-word sentences join the next — abbreviations don't flush alone")
  func abbreviations() {
    #expect(SpeechSegmenter.segments(of: "Dr. Smith is in. Go.") == ["Dr. Smith is in. Go."])
  }

  @Test("a short trailing sentence joins the previous one")
  func shortTail() {
    #expect(SpeechSegmenter.segments(of: "That went well. Thanks.") == ["That went well. Thanks."])
    #expect(SpeechSegmenter.segments(of: "Hi.") == ["Hi."])
  }

  @Test("line breaks end a segment even without punctuation")
  func lineBreaks() {
    #expect(
      SpeechSegmenter.segments(of: "Release notes here\n\nFixed the paste bug")
        == ["Release notes here", "Fixed the paste bug"])
  }

  @Test("blank input yields nothing to send")
  func blank() {
    #expect(SpeechSegmenter.segments(of: "  \n ").isEmpty)
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
