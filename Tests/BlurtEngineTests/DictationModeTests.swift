import Testing

@testable import BlurtEngine

@Suite("DictationMode")
struct DictationModeTests {
  @Test("only the cleaned mode asks for the server-side cleanup rewrite")
  func cleansUp() {
    // `cleansUp` is what `makeConfigData` reads to decide the `llm` block's
    // presence, so pin the mapping: raw omits it, cleaned includes it.
    #expect(DictationMode.raw.cleansUp == false)
    #expect(DictationMode.cleaned.cleansUp == true)
  }
}
