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

  @Test("a shorter version sorts below a longer one whose extra component is non-zero")
  func extraComponentIsNotIgnored() throws {
    // `1.2 == 1.2.0` above is satisfied even by an ordering that only walks the
    // *shorter* version's components — and that shortcut would also call 1.2 and
    // 1.2.1 equal. `UpdateChecker` gates on `current < latest`, so it would then
    // report "up to date" for a real published release and the update would never
    // be offered. Pin both directions and the inequality.
    let short = try #require(SemanticVersion("1.2"))
    let longer = try #require(SemanticVersion("1.2.1"))
    #expect(short < longer)
    #expect(!(longer < short))
    #expect(short != longer)
  }

  @Test("comparison keeps going past the third component")
  func comparesBeyondThreeComponents() throws {
    // A tag can carry a fourth component (a re-cut of a published version). It
    // must order after the three-component release it extends, not equal to it.
    let release = try #require(SemanticVersion("1.2.3"))
    let recut = try #require(SemanticVersion("1.2.3.4"))
    let laterRecut = try #require(SemanticVersion("1.2.3.5"))
    #expect(release < recut)
    #expect(recut < laterRecut)
    #expect(!(laterRecut < recut))
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

  @Test("a doubled or dangling separator is malformed, not silently collapsed")
  func rejectsEmptyComponents() {
    // The parse splits *keeping* empty subsequences, so an empty component is a
    // component that isn't a number — malformed — rather than one that quietly
    // disappears. Omitting them instead would read `v1.2.` as 1.2 and `v1..2` as
    // 1.2, and `UpdateChecker` gates the entire update decision on the parsed
    // tag: it would then compare the running build against a version the release
    // never actually stated. A tag nobody can parse has one correct outcome, the
    // `malformedResponse` throw that surfaces as "couldn't check for updates".
    #expect(SemanticVersion("1..2") == nil)
    #expect(SemanticVersion("1.2.") == nil)
    #expect(SemanticVersion(".1.2") == nil)
    #expect(SemanticVersion(".") == nil)
    // A tag that is nothing but the `v` prefix leaves an empty string behind.
    #expect(SemanticVersion("v") == nil)
  }
}
