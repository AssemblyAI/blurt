import Testing

@testable import BlurtEngine

@Suite("KeyInjector.withLeadingSeparator")
struct KeyInjectorLeadingSeparatorTests {
  @Test("prepends a space when prior text doesn't end in whitespace")
  func prependsSpace() {
    #expect(KeyInjector.withLeadingSeparator("Second.", after: "First.") == " Second.")
  }

  @Test("no separator when prior text already ends in a space")
  func priorEndsInSpace() {
    #expect(KeyInjector.withLeadingSeparator("Second.", after: "First. ") == "Second.")
  }

  @Test("no separator when prior text ends in a newline")
  func priorEndsInNewline() {
    #expect(KeyInjector.withLeadingSeparator("Second.", after: "First.\n") == "Second.")
  }

  @Test("no leading space into an empty field (nil prior text)")
  func nilPrior() {
    #expect(KeyInjector.withLeadingSeparator("Second.", after: nil) == "Second.")
  }

  @Test("no leading space when prior text is empty")
  func emptyPrior() {
    #expect(KeyInjector.withLeadingSeparator("Second.", after: "") == "Second.")
  }

  @Test("doesn't double up when the new text already starts with whitespace")
  func textStartsWithSpace() {
    #expect(KeyInjector.withLeadingSeparator(" Second.", after: "First.") == " Second.")
  }

  @Test("returns empty text unchanged")
  func emptyText() {
    #expect(KeyInjector.withLeadingSeparator("", after: "First.") == "")
  }

  @Test("every whitespace class counts, not just space and newline")
  func otherWhitespaceClasses() {
    // The rules key on Character.isWhitespace: a trailing tab, carriage return,
    // or non-breaking space suppresses the separator like a plain space does…
    #expect(KeyInjector.withLeadingSeparator("Second.", after: "First.\t") == "Second.")
    #expect(KeyInjector.withLeadingSeparator("Second.", after: "First.\r") == "Second.")
    #expect(KeyInjector.withLeadingSeparator("Second.", after: "First.\u{00A0}") == "Second.")
    // …and text already leading with a tab or non-breaking space isn't doubled.
    #expect(KeyInjector.withLeadingSeparator("\tSecond.", after: "First.") == "\tSecond.")
    #expect(KeyInjector.withLeadingSeparator("\u{00A0}Second.", after: "First.") == "\u{00A0}Second.")
  }
}

@Suite("KeyInjector.separatorBasis")
struct KeyInjectorSeparatorBasisTests {
  @Test("AX-read prior text wins even when a prior paste is on record")
  func priorTextWins() {
    #expect(
      KeyInjector.separatorBasis(priorText: "AX.", lastInserted: "Old.", sameTarget: true) == "AX.")
  }

  @Test("falls back to the last paste when AX is opaque and the target is unchanged")
  func opaqueSameTargetFallsBack() {
    #expect(
      KeyInjector.separatorBasis(priorText: nil, lastInserted: "First.", sameTarget: true)
        == "First.")
  }

  @Test("does not carry a prior paste across a different target app")
  func opaqueDifferentTargetNoFallback() {
    #expect(
      KeyInjector.separatorBasis(priorText: nil, lastInserted: "First.", sameTarget: false) == nil)
  }

  @Test("no basis when AX is opaque and nothing was pasted yet")
  func opaqueNoPriorPaste() {
    #expect(KeyInjector.separatorBasis(priorText: nil, lastInserted: nil, sameTarget: true) == nil)
  }
}
