import Foundation
import Testing

@testable import BlurtEngine

@Suite("NameMatch")
struct NameMatchTests {
  @Test("a menu item's ellipsis doesn't stop it matching")
  func menuEllipsis() {
    #expect(NameMatch.best(for: "Export", among: ["Export…", "Export as PDF…"]) == "Export…")
    #expect(NameMatch.best(for: "page setup", among: ["Page Setup..."]) == "Page Setup...")
  }
}
