import Testing

@testable import BlurtiOSCore

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
    #expect(model.termDraft?.isEmpty == true)
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
    #expect(model.termDraft?.isEmpty == true)
    model.termType("N")
    model.termSpace()
    model.termSpace()
    #expect(model.termDraft == "N ")
    model.termDelete()
    model.termDelete()
    model.termSpace()
    #expect(model.termDraft?.isEmpty == true)
  }

  @Test("return saves the term; with nothing typed it closes the field and saves nothing", .scratchSuite)
  func termReturn() {
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

  @Test("a highlighted word is the chip; one tap adds it as it stands and leaves the text alone", .scratchSuite)
  func addSelectedTerm() {
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

  @Test(
    "a word already in the key terms is known on selection; clearing the highlight takes the chip away", .scratchSuite)
  func knownSelection() {
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

  @Test(
    "holding the chip opens the field with the word; saving puts the + back though the word stays highlighted",
    .scratchSuite)
  func chipToField() {
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
