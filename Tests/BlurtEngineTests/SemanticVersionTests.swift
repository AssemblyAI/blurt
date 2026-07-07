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
  func ordersNumerically() throws {
    let v1 = try #require(SemanticVersion("0.1.9"))
    let v2 = try #require(SemanticVersion("0.1.10"))
    #expect(v1 < v2)
    let v3 = try #require(SemanticVersion("0.1.30"))
    let v4 = try #require(SemanticVersion("0.2.0"))
    #expect(v3 < v4)
    let v5 = try #require(SemanticVersion("1.0.0"))
    let v6 = try #require(SemanticVersion("2.0.0"))
    #expect(v5 < v6)
  }

  @Test("treats missing trailing components as zero")
  func padsMissingComponents() throws {
    let a = try #require(SemanticVersion("1.2"))
    let b = try #require(SemanticVersion("1.2.0"))
    #expect(a == b)
    #expect(!(a < b))
  }

  @Test("equal versions are not less than each other")
  func equalNotLess() throws {
    let v = try #require(SemanticVersion("0.1.30"))
    #expect(!(v < v))
  }

  @Test("rejects malformed strings")
  func rejectsMalformed() {
    #expect(SemanticVersion("") == nil)
    #expect(SemanticVersion("1.x.3") == nil)
    #expect(SemanticVersion("-1.0") == nil)
    #expect(SemanticVersion("abc") == nil)
  }
}
