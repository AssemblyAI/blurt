import Foundation
import Testing

@testable import BlurtEngine

@Suite("Collection.onlyElement")
struct OnlyElementTests {
  @Test("the one element when there is exactly one; none for none, or for several")
  func onlyElement() {
    #expect([7].onlyElement == 7)
    #expect([Int]().onlyElement == nil)
    #expect([7, 8].onlyElement == nil)
    #expect("x".onlyElement == "x")
    #expect("xy".onlyElement == nil)
  }
}
