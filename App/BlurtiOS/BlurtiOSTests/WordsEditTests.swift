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

  @Test("a shortcut needs a phrase with a letter or digit, and a replacement")
  func canAddShortcut() {
    #expect(WordsEdit.canAddShortcut(trigger: "my email", expansion: "me@example.com"))
    #expect(!WordsEdit.canAddShortcut(trigger: "...", expansion: "me@example.com"))
    #expect(!WordsEdit.canAddShortcut(trigger: "my email", expansion: " \n"))
  }

  @Test("a new shortcut goes on top; re-adding a phrase replaces its old replacement")
  func addsShortcuts() {
    let address = TextShortcut(trigger: "home", expansion: "1 Main St")
    let email = TextShortcut(trigger: "my email", expansion: "old@example.com")
    let added = WordsEdit.addingShortcut(trigger: "My-Email", expansion: "me@example.com", to: [address, email])
    #expect(added.map(\.trigger) == ["My-Email", "home"])
    #expect(added.map(\.expansion) == ["me@example.com", "1 Main St"])
  }
}
