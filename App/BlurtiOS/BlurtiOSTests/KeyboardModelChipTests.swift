import AssemblyAI
import Testing

@testable import BlurtiOSCore

@Suite("Keyboard model: the chip and the term field")
struct KeyboardModelChipTests {
  /// This test's own App Group: a fresh scratch suite each test, since
  /// Swift Testing runs every test on a new instance of the suite.
  let store = SharedStore.scratch()

  @Test(
    "a tap on a chip for a word Blurt has puts the + back; the chip returns for another word, or the same one again")
  func dismissKnownChip() {
    store.addKeyTerm("Rizz")
    let (model, proxy) = typingModel(store, before: "he said ", selected: "Rizz")
    model.hasFullAccess = true
    model.contextChanged()
    #expect(model.selectedTerm == "Rizz")
    #expect(model.selectedTermIsKnown)
    model.addSelectedTerm()
    #expect(model.selectedTerm == nil)
    #expect(store.keyTerms == ["Rizz"])
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

  /// The list is stored comma-separated: a chip for "Acme, Inc" used to add
  /// "Acme" and "Inc", call the phrase known, and offer it as new again.
  @Test("a highlight with a comma in it is no chip: its one tap could not add it as it stands")
  func commaIsNoChip() {
    #expect(KeyboardModel.termCandidate(from: "Acme, Inc") == nil)
    let (model, _) = typingModel(store, before: "we met ", selected: "Acme, Inc")
    model.hasFullAccess = true
    model.contextChanged()
    #expect(model.selectedTerm == nil)
    #expect(!model.selectedTermIsKnown)
    model.addSelectedTerm()
    #expect(store.keyTerms.isEmpty)
  }

  /// A request carries the first `KeyTerms.termCap` terms, the user's own
  /// first: a chip tap that added a 101st showed its ✓ for a word no dictation
  /// would ever send. At the cap the chip refuses, and the line says why.
  @Test("with the list at the cap the chip adds nothing and the status line says the list is full")
  func chipAtTheCap() {
    let full = (0..<KeyTerms.termCap).map { "term\($0)" }
    store.keyTerms = full
    let (model, proxy) = typingModel(store, before: "we met ", selected: "Zed")
    model.hasFullAccess = true
    model.contextChanged()
    #expect(model.selectedTerm == "Zed")
    model.addSelectedTerm()
    #expect(store.keyTerms == full)
    #expect(!model.selectedTermIsKnown)
    #expect(model.termSavedAt == nil)
    #expect(model.statusLine?.text == VoiceNotice.Copy.termsFull)
    // A word the full list already has is still known, not refused.
    proxy.selected = nil
    model.contextChanged()
    proxy.selected = "term7"
    model.contextChanged()
    #expect(model.selectedTermIsKnown)
  }

  @Test("with the list at the cap a typed term is refused and the field keeps what was typed")
  func typedTermAtTheCap() {
    let full = (0..<KeyTerms.termCap).map { "term\($0)" }
    store.keyTerms = full
    let (model, _) = typingModel(store, before: "he said ")
    model.hasFullAccess = true
    model.beginAddingTerm()
    model.termDraft = "Zed"
    model.saveTerm()
    #expect(store.keyTerms == full)
    #expect(model.termDraft == "Zed")
    #expect(model.termSavedAt == nil)
    #expect(model.statusLine?.text == VoiceNotice.Copy.termsFull)
  }

  @Test(
    "the + coming back after a term was added from the chip keeps the highlight's word out of the chip")
  func dismissAfterAdd() {
    let (model, _) = typingModel(store, before: "he said ", selected: "Rizz")
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
    let (model, proxy) = typingModel(store, before: "he said ", selected: "Rizz")
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
    let (model, proxy) = typingModel(store, before: "he said ", selected: "riz")
    model.hasFullAccess = true
    model.contextChanged()
    model.beginAddingTerm()
    model.termType("z")
    // The host moved the cursor but still reports the old selection for a moment.
    proxy.before = "he said riz and"
    model.saveTerm()
    #expect(store.keyTerms == ["rizz"])
    #expect(proxy.before == "he said riz and")
  }

  @Test("a key term capitalises to start and after a space, then as typed; closed, the field wants nothing")
  func termCase() {
    let (model, _) = typingModel(store)
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
