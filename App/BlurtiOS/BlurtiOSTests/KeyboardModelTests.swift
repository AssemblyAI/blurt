import Foundation
import Testing
import UIKit

@testable import BlurtiOSCore

/// A host text field the model can type into, remembering what it did.
final class FakeProxy: NSObject, UITextDocumentProxy {
  var before = ""
  var after = ""
  var selected: String?
  var autocapitalizationType: UITextAutocapitalizationType = .sentences
  var keyboardType: UIKeyboardType = .default
  var returnKeyType: UIReturnKeyType = .default

  var documentContextBeforeInput: String? { before }
  var documentContextAfterInput: String? { after }
  var selectedText: String? { selected }
  var documentInputMode: UITextInputMode? { nil }
  var documentIdentifier = UUID()
  var hasText: Bool { !before.isEmpty || !after.isEmpty }

  func insertText(_ text: String) {
    if let selected, !selected.isEmpty {
      self.selected = nil
    }
    before += text
  }

  func deleteBackward() { _ = before.popLast() }
  func adjustTextPosition(byCharacterOffset offset: Int) {}
  func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
  func unmarkText() {}
}

/// A bare keyboard over a fake field holding `before` up to the caret, with
/// `selected` highlighted: what the typing and chip rules read.
private func typingModel(before: String = "", selected: String? = nil) -> (KeyboardModel, FakeProxy) {
  let proxy = FakeProxy()
  proxy.before = before
  proxy.selected = selected
  let model = KeyboardModel()
  model.proxyOverride = proxy
  return (model, proxy)
}

@Suite("Keyboard model: typing rules")
struct KeyboardModelTypingTests {
  @Test("the term field takes the keys instead of the host; closed, its keys do nothing")
  func termField() {
    let (model, proxy) = typingModel(before: "yo ")
    model.termType("x")
    model.termSpace()
    model.termDelete()
    model.termReturn()
    #expect(model.termDraft == nil)
    #expect(proxy.before == "yo ")
    model.beginAddingTerm()
    #expect(model.termDraft == "")
    model.termType("R")
    model.termType("i")
    model.termSpace()
    model.termType("z")
    model.termDelete()
    #expect(model.termDraft == "Ri ")
    #expect(proxy.before == "yo ")
    model.cancelAddingTerm()
    #expect(model.termDraft == nil)
  }

  @Test("a space in the term is one between words: never first, never a run")
  func termSpace() {
    let (model, _) = typingModel()
    model.beginAddingTerm()
    model.termSpace()
    #expect(model.termDraft == "")
    model.termType("N")
    model.termSpace()
    model.termSpace()
    #expect(model.termDraft == "N ")
    model.termDelete()
    model.termDelete()
    model.termSpace()
    #expect(model.termDraft == "")
  }

  @Test("return saves the term; with nothing typed it closes the field and saves nothing")
  func termReturn() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (model, _) = typingModel()
    model.hasFullAccess = true
    model.beginAddingTerm()
    model.termReturn()
    #expect(model.termDraft == nil)
    #expect(SharedStore.keyTerms.isEmpty)
    model.beginAddingTerm()
    model.termType("R")
    model.termType("i")
    model.termReturn()
    #expect(model.termDraft == nil)
    #expect(SharedStore.keyTerms == ["Ri"])
  }

  @Test("a selection seeds the term and is replaced on save")
  func termFromSelection() {
    let (model, proxy) = typingModel(before: "he said ", selected: "riz")
    model.beginAddingTerm()
    #expect(model.termDraft == "riz")
    model.termType("z")
    model.saveTerm()
    #expect(model.termDraft == nil)
    #expect(proxy.before == "he said rizz")
  }

  @Test("typing that reached the host field while the term is open moves into the term")
  func hardwareTypingClaimed() {
    let (model, proxy) = typingModel(before: "yo ")
    model.beginAddingTerm()
    // A hardware key is one character per change.
    proxy.before = "yo R"
    model.contextChanged()
    proxy.before = "yo i"
    model.contextChanged()
    #expect(model.termDraft == "Ri")
    #expect(proxy.before == "yo ")
    // A block landing at once (a paste, the system's dictation) is not typing.
    proxy.before = "yo hello"
    model.contextChanged()
    #expect(model.termDraft == "Ri")
    #expect(proxy.before == "yo hello")
  }

  // MARK: The chip for a highlighted word

  @Test("a selection is a key-term candidate when trimmed, on one line and short")
  func termCandidate() {
    #expect(KeyboardModel.termCandidate(from: " Rizz ") == "Rizz")
    #expect(KeyboardModel.termCandidate(from: "Neil Bisht") == "Neil Bisht")
    #expect(KeyboardModel.termCandidate(from: nil) == nil)
    #expect(KeyboardModel.termCandidate(from: "   ") == nil)
    #expect(KeyboardModel.termCandidate(from: "two\nlines") == nil)
    #expect(KeyboardModel.termCandidate(from: String(repeating: "a", count: KeyboardModel.termLengthCap)) != nil)
    #expect(KeyboardModel.termCandidate(from: String(repeating: "a", count: KeyboardModel.termLengthCap + 1)) == nil)
  }

  @Test("a highlighted word is the chip; one tap adds it as it stands and leaves the text alone")
  func addSelectedTerm() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (model, proxy) = typingModel(before: "he said ", selected: "Rizz")
    model.hasFullAccess = true
    model.contextChanged()
    #expect(model.selectedTerm == "Rizz")
    #expect(!model.selectedTermIsKnown)
    model.addSelectedTerm()
    #expect(SharedStore.keyTerms == ["Rizz"])
    #expect(model.selectedTermIsKnown)
    #expect(model.termSavedAt != nil)
    #expect(model.termDraft == nil)
    #expect(proxy.before == "he said ")
    #expect(proxy.selected == "Rizz")
    // A second tap adds nothing twice.
    model.addSelectedTerm()
    #expect(SharedStore.keyTerms == ["Rizz"])
  }

  @Test("a word already in the key terms is known on selection; clearing the highlight takes the chip away")
  func knownSelection() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    SharedStore.addKeyTerm("rizz")
    let (model, proxy) = typingModel(before: "he said ", selected: "Rizz")
    model.hasFullAccess = true
    model.contextChanged()
    #expect(model.selectedTerm == "Rizz")
    #expect(model.selectedTermIsKnown)
    proxy.selected = nil
    model.contextChanged()
    #expect(model.selectedTerm == nil)
    #expect(!model.selectedTermIsKnown)
  }

  @Test("no chip without Full Access, or for a selection that is no term")
  func noChip() {
    let (model, proxy) = typingModel(before: "", selected: "Rizz")
    model.contextChanged()
    #expect(model.selectedTerm == nil)
    model.hasFullAccess = true
    proxy.selected = "a whole\nparagraph"
    model.contextChanged()
    #expect(model.selectedTerm == nil)
  }

  @Test("holding the chip opens the field with the word; saving puts the + back though the word stays highlighted")
  func chipToField() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let (model, proxy) = typingModel(before: "he said ", selected: "riz")
    model.hasFullAccess = true
    model.contextChanged()
    model.beginAddingTerm()
    #expect(model.termDraft == "riz")
    model.saveTerm()
    #expect(SharedStore.keyTerms == ["riz"])
    #expect(proxy.before == "he said ")
    #expect(proxy.selected == "riz")
    #expect(model.selectedTerm == nil)
    #expect(model.termSavedAt != nil)
    // The host still reports the highlight on the next change: no chip.
    model.contextChanged()
    #expect(model.selectedTerm == nil)
  }
}

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
