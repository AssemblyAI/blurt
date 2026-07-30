import Testing

@testable import BlurtEngine

/// `assigning` is the one place the "the two dictation keys must stay distinct"
/// rule lives, so pin its three cases: a clean assign, a colliding assign that
/// swaps, and a no-op assign to the key a mode already holds.
@Suite("DictationTriggerPair")
struct DictationTriggerPairTests {
  @Test("assigning a free key to a mode leaves the other mode untouched")
  func assignWithoutCollision() {
    let pair = DictationTriggerPair(raw: .rightOption, cleaned: .rightCommand)
    let updated = pair.assigning(.raw, to: .function)
    #expect(updated == DictationTriggerPair(raw: .function, cleaned: .rightCommand))
  }

  @Test("assigning a free key to the cleaned mode leaves the other mode untouched")
  func assignCleanedWithoutCollision() {
    let pair = DictationTriggerPair(raw: .rightOption, cleaned: .rightCommand)
    let updated = pair.assigning(.cleaned, to: .function)
    #expect(updated == DictationTriggerPair(raw: .rightOption, cleaned: .function))
  }

  @Test("assigning a mode the other mode's key swaps them, preserving distinctness")
  func assignWithCollisionSwaps() {
    let pair = DictationTriggerPair(raw: .rightOption, cleaned: .rightCommand)
    // Ask raw to take the cleaned key: cleaned takes raw's vacated key (a swap)
    // rather than both landing on right ⌘.
    let updated = pair.assigning(.raw, to: .rightCommand)
    #expect(updated == DictationTriggerPair(raw: .rightCommand, cleaned: .rightOption))
    #expect(updated.raw != updated.cleaned)
  }

  @Test("the swap works symmetrically from the cleaned side")
  func assignCleanedWithCollisionSwaps() {
    let pair = DictationTriggerPair(raw: .rightOption, cleaned: .rightCommand)
    let updated = pair.assigning(.cleaned, to: .rightOption)
    #expect(updated == DictationTriggerPair(raw: .rightCommand, cleaned: .rightOption))
  }

  @Test("assigning a mode the key it already holds is a no-op")
  func assignSelfIsNoOp() {
    let pair = DictationTriggerPair(raw: .rightOption, cleaned: .rightCommand)
    #expect(pair.assigning(.raw, to: .rightOption) == pair)
    #expect(pair.assigning(.cleaned, to: .rightCommand) == pair)
  }
}
