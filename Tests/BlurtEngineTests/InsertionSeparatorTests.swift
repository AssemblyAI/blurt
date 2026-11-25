import Testing

@testable import BlurtEngine

@Suite("InsertionSeparator.withLeadingSeparator")
struct InsertionSeparatorTests {
  @Test("prepends a space when prior text doesn't end in whitespace")
  func prependsSpace() {
    #expect(InsertionSeparator.withLeadingSeparator("Second.", after: "First.") == " Second.")
  }

  @Test("no separator when prior text already ends in a space")
  func priorEndsInSpace() {
    #expect(InsertionSeparator.withLeadingSeparator("Second.", after: "First. ") == "Second.")
  }

  @Test("no separator when prior text ends in a newline")
  func priorEndsInNewline() {
    #expect(InsertionSeparator.withLeadingSeparator("Second.", after: "First.\n") == "Second.")
  }

  @Test("no leading space into an empty field (nil prior text)")
  func nilPrior() {
    #expect(InsertionSeparator.withLeadingSeparator("Second.", after: nil) == "Second.")
  }

  @Test("no leading space when prior text is empty")
  func emptyPrior() {
    #expect(InsertionSeparator.withLeadingSeparator("Second.", after: "") == "Second.")
  }

  @Test("doesn't double up when the new text already starts with whitespace")
  func textStartsWithSpace() {
    #expect(InsertionSeparator.withLeadingSeparator(" Second.", after: "First.") == " Second.")
  }

  @Test("returns empty text unchanged")
  func emptyText() {
    #expect(InsertionSeparator.withLeadingSeparator("", after: "First.").isEmpty)
  }

  @Test("every whitespace class counts, not just space and newline")
  func otherWhitespaceClasses() {
    // The rules key on Character.isWhitespace: a trailing tab, carriage return,
    // or non-breaking space suppresses the separator like a plain space does…
    #expect(InsertionSeparator.withLeadingSeparator("Second.", after: "First.\t") == "Second.")
    #expect(InsertionSeparator.withLeadingSeparator("Second.", after: "First.\r") == "Second.")
    #expect(InsertionSeparator.withLeadingSeparator("Second.", after: "First.\u{00A0}") == "Second.")
    // …and text already leading with a tab or non-breaking space isn't doubled.
    #expect(InsertionSeparator.withLeadingSeparator("\tSecond.", after: "First.") == "\tSecond.")
    #expect(InsertionSeparator.withLeadingSeparator("\u{00A0}Second.", after: "First.") == "\u{00A0}Second.")
  }

  @Test(
    "no separator after an opener (bracket, opening quote, @, $)",
    arguments: [
      "Call me (",
      "a [",
      "a {",
      "She said \u{201C}",
      "She said \u{2018}",
      "Il a dit \u{00AB}",
      "Dijo \u{00BF}",
      "Dijo \u{00A1}",
      "ping @",
      "price: $",
    ])
  func noSeparatorAfterOpener(prior: String) {
    #expect(InsertionSeparator.withLeadingSeparator("Maybe tomorrow.", after: prior) == "Maybe tomorrow.")
  }

  @Test(
    "a straight quote or # opens after whitespace or at the start",
    arguments: ["She said \"", "She said '", "\"", "'", "Line one.\n\"", "post in #", "#"])
  func noSeparatorAfterWordStartOpener(prior: String) {
    #expect(InsertionSeparator.withLeadingSeparator("Maybe.", after: prior) == "Maybe.")
  }

  @Test(
    "a closing quote, a closing bracket or a # suffix keeps the separator",
    arguments: ["She said \"hi\"", "the 'word'", "Call me (maybe)", "a [b]", "I write C#"])
  func separatorAfterCloser(prior: String) {
    #expect(InsertionSeparator.withLeadingSeparator("Then.", after: prior) == " Then.")
  }

  // `withLeadingSeparator` returns before asking about an empty prior text, so
  // only a direct call pins what `endsInOpener` says about one.
  @Test("empty prior text ends in no opener")
  func emptyPriorTextIsNoOpener() {
    #expect(!InsertionSeparator.endsInOpener(""))
  }
}
