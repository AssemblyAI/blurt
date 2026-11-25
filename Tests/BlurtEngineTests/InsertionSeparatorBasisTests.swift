import Foundation
import Testing

@testable import BlurtEngine

@Suite("InsertionSeparator.basis")
struct InsertionSeparatorBasisTests {
  @Test("AX-read prior text wins even when a prior paste is on record")
  func priorTextWins() {
    #expect(
      InsertionSeparator.basis(priorText: "AX.", lastInserted: "Old.", sameWindow: false) == "AX.")
  }

  @Test("falls back to the last paste when AX is opaque and the window is unchanged")
  func opaqueSameWindowFallsBack() {
    #expect(
      InsertionSeparator.basis(priorText: nil, lastInserted: "First.", sameWindow: true)
        == "First.")
  }

  @Test("does not carry a prior paste across a different window")
  func opaqueDifferentWindowNoFallback() {
    #expect(
      InsertionSeparator.basis(priorText: nil, lastInserted: "First.", sameWindow: false) == nil)
  }

  @Test("no basis when AX is opaque and nothing was pasted yet")
  func opaqueNoPriorPaste() {
    #expect(InsertionSeparator.basis(priorText: nil, lastInserted: nil, sameWindow: true) == nil)
  }
}
