import Foundation
import Testing
import UIKit

@testable import BlurtiOSCore

@Suite("Keyboard model: the chip and the term field")
struct KeyboardModelChipTests {
  @Test(
    "a tap on a chip for a word Blurt has puts the + back; the chip returns for another word, or the same one again")
  func dismissKnownChip() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.addKeyTerm("Rizz")
    let (model, proxy) = typingModel(before: "he said ", selected: "Rizz")
    model.hasFullAccess = true
    model.contextChanged()
    #expect(model.selectedTerm == "Rizz")
    #expect(model.selectedTermIsKnown)
    model.addSelectedTerm()
    #expect(model.selectedTerm == nil)
    #expect(SharedStore.keyTerms == ["Rizz"])
    model.contextChanged()
    #expect(model.selectedTerm == nil)
    // Another word highlighted: its chip.
    proxy.selected = "Gyatt"
    model.contextChanged()
    #expect(model.selectedTerm == "Gyatt")
    #expect(!model.selectedTermIsKnown)
    // The highlight cleared and the first word highlighted again: known again.
    proxy.selected = nil
    model.contextChanged()
    proxy.selected = "Rizz"
    model.contextChanged()
    #expect(model.selectedTerm == "Rizz")
    #expect(model.selectedTermIsKnown)
  }

  @Test("the + coming back after a term was added from the chip keeps the highlight's word out of the chip")
  func dismissAfterAdd() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (model, _) = typingModel(before: "he said ", selected: "Rizz")
    model.hasFullAccess = true
    model.contextChanged()
    model.addSelectedTerm()
    // While the check shows, the chip is still up with it.
    #expect(model.selectedTerm == "Rizz")
    #expect(model.selectedTermIsKnown)
    model.dismissSelection()
    #expect(model.selectedTerm == nil)
    model.contextChanged()
    #expect(model.selectedTerm == nil)
  }

  @Test("collapsing the highlight the field opened over is not typing: the word stays in the text")
  func collapseIsNotTyping() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (model, proxy) = typingModel(before: "he said ", selected: "Rizz")
    proxy.after = " today"
    model.hasFullAccess = true
    model.contextChanged()
    model.beginAddingTerm()
    #expect(model.termDraft == "Rizz")
    // The user taps at the end of the word: the highlight collapses there.
    proxy.selected = nil
    proxy.before = "he said Rizz"
    model.contextChanged()
    #expect(proxy.before == "he said Rizz")
    #expect(model.termDraft == "Rizz")
  }

  @Test("saving does not replace the word once the cursor has moved off the highlight")
  func noReplaceAfterCursorMove() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (model, proxy) = typingModel(before: "he said ", selected: "riz")
    model.hasFullAccess = true
    model.contextChanged()
    model.beginAddingTerm()
    model.termType("z")
    // The host moved the cursor but still reports the old selection for a moment.
    proxy.before = "he said riz and"
    model.saveTerm()
    #expect(SharedStore.keyTerms == ["rizz"])
    #expect(proxy.before == "he said riz and")
  }

  @Test("a key term capitalises to start and after a space, then as typed; closed, the field wants nothing")
  func termCase() {
    let (model, _) = typingModel()
    #expect(!model.termWantsUppercase)
    model.beginAddingTerm()
    #expect(model.termWantsUppercase)
    model.termType("N")
    #expect(!model.termWantsUppercase)
    model.termSpace()
    #expect(model.termWantsUppercase)
    model.termType("B")
    #expect(!model.termWantsUppercase)
    #expect(model.termDraft == "N B")
    model.cancelAddingTerm()
    #expect(!model.termWantsUppercase)
  }
}
