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
    let nearlyFull = Array(full.dropLast())
    #expect(WordsEdit.addingKeyTerms("one, two", to: nearlyFull) == nearlyFull + ["one"])
  }

  /// The keyboard's + and a shared list add without the cap, so the list can
  /// be over it; a term typed in the Words tab then (Return still submits with
  /// Add disabled) used to cut the list back to the cap, deleting the rest.
  @Test("adding to a list already over the cap keeps every term it had and adds nothing")
  func overTheCapKeepsTheList() {
    let over = (0..<(KeyTerms.termCap + 5)).map { "t\($0)" }
    #expect(WordsEdit.addingKeyTerms("one more", to: over) == over)
    #expect(WordsEdit.addingKeyTerms("t3", to: over) == over)
  }
}
