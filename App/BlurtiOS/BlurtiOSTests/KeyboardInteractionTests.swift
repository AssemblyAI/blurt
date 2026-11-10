import CoreGraphics
import Testing

@testable import BlurtiOSCore

@Suite("Keyboard interaction rules")
struct KeyboardInteractionTests {
  @Test("the chip acts only under 12 pt of travel")
  func travel() {
    #expect(KeyboardInteraction.isTap(CGSize(width: 11.9, height: 11.9)))
    #expect(!KeyboardInteraction.isTap(CGSize(width: 12, height: 0)))
    #expect(!KeyboardInteraction.isTap(CGSize(width: 0, height: -12)))
  }
}
