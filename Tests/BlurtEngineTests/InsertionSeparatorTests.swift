import Testing

@testable import BlurtEngine

@Suite("InsertionSeparator.withLeadingSeparator")
struct InsertionSeparatorTests {
  /// One `withLeadingSeparator(_:after:)` expectation: the text being inserted,
  /// the text already before the caret, and what actually gets inserted.
  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    let text: String
    let prior: String?
    let expected: String
    var testDescription: String { name }
  }

  static let cases: [Case] = [
    Case(
      name: "prepends a space when prior text doesn't end in whitespace",
      text: "Second.",
      prior: "First.",
      expected: " Second."
    ),
    Case(
      name: "no separator when prior text already ends in a space",
      text: "Second.",
      prior: "First. ",
      expected: "Second."
    ),
    Case(
      name: "no separator when prior text ends in a newline",
      text: "Second.",
      prior: "First.\n",
      expected: "Second."
    ),
    Case(
      name: "no leading space into an empty field (nil prior text)",
      text: "Second.",
      prior: nil,
      expected: "Second."
    ),
    Case(name: "no leading space when prior text is empty", text: "Second.", prior: "", expected: "Second."),
    Case(
      name: "doesn't double up when the new text already starts with whitespace",
      text: " Second.",
      prior: "First.",
      expected: " Second."
    ),
    Case(name: "returns empty text unchanged", text: "", prior: "First.", expected: ""),
    // The rules key on Character.isWhitespace: a trailing tab, carriage return,
    // or non-breaking space suppresses the separator like a plain space does…
    Case(name: "a trailing tab counts as whitespace", text: "Second.", prior: "First.\t", expected: "Second."),
    Case(
      name: "a trailing carriage return counts as whitespace",
      text: "Second.",
      prior: "First.\r",
      expected: "Second."
    ),
    Case(
      name: "a trailing non-breaking space counts as whitespace",
      text: "Second.",
      prior: "First.\u{00A0}",
      expected: "Second."
    ),
    // …and text already leading with a tab or non-breaking space isn't doubled.
    Case(
      name: "text leading with a tab isn't doubled",
      text: "\tSecond.",
      prior: "First.",
      expected: "\tSecond."
    ),
    Case(
      name: "text leading with a non-breaking space isn't doubled",
      text: "\u{00A0}Second.",
      prior: "First.",
      expected: "\u{00A0}Second."
    ),
  ]

  @Test("the separator depends on the prior text's end and the new text's start", arguments: cases)
  func separator(_ c: Case) {
    #expect(InsertionSeparator.withLeadingSeparator(c.text, after: c.prior) == c.expected)
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
}
