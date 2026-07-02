import Testing

@testable import BlurtEngine

/// Exercises `Optional<String>.trimmedNonEmpty()` — the single definition of
/// "usable text" shared by focus capture, the transcription context/prompt, and
/// the key-term/key stores. It's relied on transitively by most of those suites
/// but never asserted directly, so a change to the trim-and-treat-blank-as-empty
/// rule could slip through. These pin it down.
@Suite("String.trimmedNonEmpty")
struct StringNormalizationTests {

  @Test("nil stays nil")
  func nilStaysNil() {
    let value: String? = nil
    #expect(value.trimmedNonEmpty() == nil)
  }

  @Test("empty string becomes nil")
  func emptyBecomesNil() {
    let value: String? = ""
    #expect(value.trimmedNonEmpty() == nil)
  }

  @Test("blank strings (spaces, tabs, newlines) become nil")
  func blankBecomesNil() {
    #expect(("   " as String?).trimmedNonEmpty() == nil)
    #expect(("\t" as String?).trimmedNonEmpty() == nil)
    #expect(("\n" as String?).trimmedNonEmpty() == nil)
    #expect((" \t\n " as String?).trimmedNonEmpty() == nil)
  }

  @Test("surrounding whitespace and newlines are trimmed")
  func trimsSurroundingWhitespace() {
    #expect(("  hello  " as String?).trimmedNonEmpty() == "hello")
    #expect(("\nhello\t" as String?).trimmedNonEmpty() == "hello")
  }

  @Test("a clean string passes through unchanged")
  func cleanStringUnchanged() {
    #expect(("hello" as String?).trimmedNonEmpty() == "hello")
  }

  @Test("interior whitespace is preserved")
  func interiorWhitespacePreserved() {
    #expect(("  a b c  " as String?).trimmedNonEmpty() == "a b c")
    #expect(("line one\nline two" as String?).trimmedNonEmpty() == "line one\nline two")
  }

  @Test("the non-optional String companion applies the same rule")
  func nonOptionalCompanion() {
    // Used directly on plain Strings (API key, transcript); every case above
    // goes through the Optional overload, so pin this entry point too.
    #expect("  hello  ".trimmedNonEmpty() == "hello")
    #expect("".trimmedNonEmpty() == nil)
    #expect("  \n ".trimmedNonEmpty() == nil)
  }
}
