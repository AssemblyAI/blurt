import AssemblyAI
import Testing

@testable import BlurtiOSCore

@Suite("Words tab edits")
struct WordsEditTests {
  @Test("adding key terms appends them, splitting on commas and dropping duplicates of any case")
  func addsKeyTerms() {
    #expect(WordsEdit.addingKeyTerms("Neil Bisht, blurt", to: ["Blurt"]) == ["Blurt", "Neil Bisht"])
    #expect(WordsEdit.addingKeyTerms("  ", to: ["Blurt"]) == ["Blurt"])
  }

  @Test("key terms stop at the request's term cap, so nothing is kept that couldn't be sent")
  func keyTermsStopAtTheCap() {
    let full = (0..<KeyTerms.termCap).map { "t\($0)" }
    #expect(WordsEdit.addingKeyTerms("one more", to: full) == full)
  }
}
