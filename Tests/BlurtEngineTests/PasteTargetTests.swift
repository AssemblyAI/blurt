#if os(macOS)
  import Testing

  @testable import BlurtEngine

  /// The paste decision one fact at a time, beside the recorded situations
  /// `PasteFixtureTests` replays: each signal alone is enough to paste, and
  /// none of them is assumed when it wasn't read.
  @Suite("PasteTarget")
  struct PasteTargetTests {
    /// A focused native button: nothing about it takes text.
    private let button = PasteFacts(focused: true, role: "AXButton", bundleID: "com.apple.finder")

    @Test("a focused element that reads as nothing editable copies; a fact left unread is never assumed")
    func nothingEditableCopies() {
      #expect(!PasteTarget.pastes(button))
      #expect(!PasteTarget.fieldTakesPaste(button))
    }

    @Test("each editable signal alone is enough: a settable value, an insertion point, a web page, an editable role")
    func eachSignalPastes() {
      var settable = button
      settable.valueSettable = true
      var caret = button
      caret.hasInsertionPoint = true
      var page = button
      page.inWebArea = true
      let field = PasteFacts(focused: true, role: "AXTextField", bundleID: "com.apple.finder")
      for facts in [settable, caret, page, field] {
        #expect(PasteTarget.pastes(facts), "\(facts)")
      }
    }

    @Test("nothing focused copies, whatever the facts read off it would say")
    func nothingFocusedCopies() {
      var facts = PasteFacts(focused: false, role: "AXTextField", valueSettable: true, hasInsertionPoint: true)
      facts.bundleID = "com.apple.finder"
      #expect(!PasteTarget.pastes(facts))
    }

    @Test("an app that hides its fields pastes on no signal: a browser, a custom-drawn editor, or Electron, each alone")
    func opaqueAppsPaste() {
      let nothing = PasteFacts(focused: false)
      var browser = nothing
      browser.bundleID = "com.google.Chrome"
      var editor = nothing
      editor.bundleID = "com.sublimetext.4"
      var electron = nothing
      electron.bundleID = "com.example.app"
      electron.electron = true
      for facts in [browser, editor, electron] {
        #expect(PasteTarget.pastes(facts), "\(facts)")
      }
      #expect(!PasteTarget.pastes(nothing))
    }
  }
#endif
