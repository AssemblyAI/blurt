import Testing

@testable import BlurtEngine

@Suite("SemanticVersion")
struct SemanticVersionTests {
  @Test("parses a bare dotted version")
  func parsesBare() {
    let version = SemanticVersion("0.1.30")
    #expect(version != nil)
    #expect(version?.description == "0.1.30")
  }

  @Test("parses a v-prefixed tag")
  func parsesVPrefixed() {
    #expect(SemanticVersion("v0.1.30")?.description == "0.1.30")
    #expect(SemanticVersion("V2.0.0")?.description == "2.0.0")
  }

  @Test("orders by numeric components, not lexically")
  func ordersNumerically() {
    #expect(SemanticVersion("0.1.9")! < SemanticVersion("0.1.10")!)
    #expect(SemanticVersion("0.1.30")! < SemanticVersion("0.2.0")!)
    #expect(SemanticVersion("1.0.0")! < SemanticVersion("2.0.0")!)
  }

  @Test("treats missing trailing components as zero")
  func padsMissingComponents() {
    #expect(SemanticVersion("1.2") == SemanticVersion("1.2.0"))
    #expect(!(SemanticVersion("1.2")! < SemanticVersion("1.2.0")!))
  }

  @Test("equal versions are not less than each other")
  func equalNotLess() {
    #expect(!(SemanticVersion("0.1.30")! < SemanticVersion("0.1.30")!))
  }

  @Test("rejects malformed strings")
  func rejectsMalformed() {
    #expect(SemanticVersion("") == nil)
    #expect(SemanticVersion("1.x.3") == nil)
    #expect(SemanticVersion("-1.0") == nil)
    #expect(SemanticVersion("abc") == nil)
  }
}
