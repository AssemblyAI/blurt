import XCTest

/// The main window's transcription features: the Recent history (its filter,
/// search, ⌘F, opening, deleting), the transcript sheet (speaker turns, Plain
/// text, a task on the LLM), transcribing a file, the toolbar's Record and Browse, and
/// the auto-record setting.
///
/// Runs on the ready screen against a seeded, throwaway history
/// (`-BlurtUITestSeedHistory`: a two-speaker recording, a dictation, a
/// read-aloud clip) and a canned transport standing in for the async API and
/// the LLM Gateway, so nothing touches the network or the user's history.
/// Recording itself isn't driven here: it needs real microphone and
/// system-audio grants, which the test host can't give.
final class TranscriptionUITests: BlurtUITestCase {
  override var extraLaunchArguments: [String] {
    [UITestIdentifiers.readyLaunchArgument, UITestIdentifiers.seedHistoryLaunchArgument]
  }

  // MARK: - Recent list

  func testSeededHistoryIsListedAndFiltered() {
    mainWindow()
    XCTAssertTrue(row(titled: UITestIdentifiers.seededRecordingTitle).waitForExistence(timeout: 10))
    XCTAssertTrue(row(titled: UITestIdentifiers.seededDictationText).exists)
    XCTAssertTrue(row(titled: UITestIdentifiers.seededReadText).exists)

    selectFilter("Dictations")
    XCTAssertTrue(row(titled: UITestIdentifiers.seededDictationText).waitForExistence(timeout: 5))
    XCTAssertFalse(row(titled: UITestIdentifiers.seededRecordingTitle).exists, "Dictations hides recordings")

    selectFilter("Recordings")
    XCTAssertTrue(row(titled: UITestIdentifiers.seededRecordingTitle).waitForExistence(timeout: 5))
    XCTAssertFalse(row(titled: UITestIdentifiers.seededDictationText).exists, "Recordings hides dictations")

    selectFilter("Files")
    XCTAssertFalse(row(titled: UITestIdentifiers.seededRecordingTitle).exists, "Files hides recordings")

    selectFilter("Spoken")
    XCTAssertTrue(row(titled: UITestIdentifiers.seededReadText).waitForExistence(timeout: 5))
    XCTAssertFalse(row(titled: UITestIdentifiers.seededRecordingTitle).exists, "Spoken hides recordings")

    selectFilter("All")
    XCTAssertTrue(row(titled: UITestIdentifiers.seededRecordingTitle).waitForExistence(timeout: 5))
  }

  func testSearchFiltersAndFindFocusesIt() {
    mainWindow()
    XCTAssertTrue(row(titled: UITestIdentifiers.seededRecordingTitle).waitForExistence(timeout: 10))

    // ⌘F puts the cursor in the search field; typing filters at once. "roadmap"
    // is only in the recording's transcript, not its title: a full-text match.
    app.typeKey("f", modifierFlags: .command)
    app.typeText("roadmap")
    XCTAssertTrue(row(titled: UITestIdentifiers.seededRecordingTitle).waitForExistence(timeout: 5))
    XCTAssertFalse(row(titled: UITestIdentifiers.seededDictationText).exists)

    // Nothing matches: the system's no-results state.
    // The window's toolbar search, the only search field in the main window.
    let search = app.windows[UITestIdentifiers.mainWindowTitle].searchFields.firstMatch
    XCTAssertTrue(search.exists, "The main window should have a search field")
    search.typeText("zzqx")
    XCTAssertTrue(
      text(containing: "No results").waitForExistence(timeout: 5), "A search with no matches should say so")
  }

  // MARK: - Open item

  func testOpeningARecordingShowsSpeakersPlainTextAndATask() {
    mainWindow()
    let recording = row(titled: UITestIdentifiers.seededRecordingTitle)
    XCTAssertTrue(recording.waitForExistence(timeout: 10))
    recording.doubleClick()

    // Full: the turns, each under its speaker.
    XCTAssertTrue(windowText(containing: "Speaker A").waitForExistence(timeout: 5), "Full shows speaker A's turn")
    XCTAssertTrue(windowText(containing: "Speaker B").exists, "Full shows speaker B's turn")
    XCTAssertTrue(windowText(containing: UITestIdentifiers.seededRecordingSpeakerA).exists)

    // Plain text: the same words, no labels.
    showView("Plain text")
    let plain = "\(UITestIdentifiers.seededRecordingSpeakerA) \(UITestIdentifiers.seededRecordingSpeakerB)"
    XCTAssertTrue(windowText(containing: plain).waitForExistence(timeout: 5), "Plain text shows the unlabelled words")

    // A task: the canned gateway's answer lands in the text area.
    showView("Meeting notes")
    XCTAssertTrue(
      windowText(containing: UITestIdentifiers.cannedTaskResult).waitForExistence(timeout: 10),
      "Meeting notes shows the LLM's result")

    // Esc pops back to the Library, as the navigation's back button does.
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertFalse(viewPicker.waitForExistence(timeout: 2), "Esc returns to the Library")
  }

  func testDeleteAsksThenRemovesTheEntry() {
    mainWindow()
    let dictation = row(titled: UITestIdentifiers.seededDictationText)
    XCTAssertTrue(dictation.waitForExistence(timeout: 10))
    dictation.rightClick()
    let delete = app.menuItems["Delete…"]
    XCTAssertTrue(delete.waitForExistence(timeout: 5), "The row's menu offers Delete…")
    delete.click()

    // The confirmation — a sheet on the window — with Delete as the
    // destructive choice. Scoped to the sheet: a bare query also matches the
    // Touch Bar's Delete.
    let confirm = app.windows[UITestIdentifiers.mainWindowTitle].sheets.buttons["Delete"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Deleting asks first")
    confirm.click()
    let gone = NSPredicate(format: "exists == false")
    expectation(for: gone, evaluatedWith: row(titled: UITestIdentifiers.seededDictationText))
    waitForExpectations(timeout: 5)
    XCTAssertTrue(row(titled: UITestIdentifiers.seededRecordingTitle).exists, "Only that entry goes")
  }

  // MARK: - Controls and settings

  func testToolbarControlsAndAutoRecordSetting() {
    let main = mainWindow()
    XCTAssertTrue(main.buttons[UITestIdentifiers.transcribeRecordButton].waitForExistence(timeout: 10))
    XCTAssertTrue(main.buttons[UITestIdentifiers.transcribeRecordButton].isEnabled)
    XCTAssertTrue(main.buttons[UITestIdentifiers.transcribeBrowseButton].exists)

    let settings = openSettingsWindow()
    let toggle = settings.descendants(matching: .any)[UITestIdentifiers.autoRecordToggle].firstMatch
    XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Settings › General has Auto-record meetings")
    XCTAssertEqual(toggle.value as? Int, 0, "Auto-record is off until the user turns it on")
    toggle.click()
    XCTAssertEqual(toggle.value as? Int, 1)
    toggle.click()
    XCTAssertEqual(toggle.value as? Int, 0)
  }

  // MARK: - Helpers

  /// A Library row by its title. The row is one combined element whose text
  /// ("<title>, <details>") XCUITest may report as its label or its value.
  private func row(titled title: String) -> XCUIElement {
    app.windows[UITestIdentifiers.mainWindowTitle].descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", title, title)).firstMatch
  }

  /// Static text in the main window containing `text`. A typed query:
  /// matching `.any` element across the window is slow enough on this
  /// hierarchy for XCUITest to time out.
  private func text(containing text: String) -> XCUIElement {
    app.windows[UITestIdentifiers.mainWindowTitle].staticTexts
      .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
  }

  /// Anything in the app showing `text` — the open item's transcript. A speaker turn is one combined element — a group,
  /// not static text — so any type is matched.
  private func windowText(containing text: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
  }

  /// The open item's toolbar View menu.
  private var viewPicker: XCUIElement {
    app.menuButtons[UITestIdentifiers.facetPicker].firstMatch
  }

  /// Shows the view titled `title`, from the toolbar's View menu.
  private func showView(_ title: String) {
    XCTAssertTrue(viewPicker.waitForExistence(timeout: 5), "The open item's View menu not found")
    viewPicker.click()
    viewPicker.menuItems[title].click()
  }

  /// A kind from the toolbar's Filter menu.
  private func selectFilter(_ title: String) {
    let menu = app.windows[UITestIdentifiers.mainWindowTitle].menuButtons[UITestIdentifiers.libraryFilterMenu]
    XCTAssertTrue(menu.waitForExistence(timeout: 3), "The Filter menu not found")
    menu.click()
    app.menuItems[title].click()
  }
}

/// Transcribing a file end to end: launched with `-BlurtUITestTranscribeSample`,
/// the app transcribes a sample file at launch through the canned async API —
/// XCUITest can't drive a Finder drag — and names it with the canned LLM.
final class TranscribeFileUITests: BlurtUITestCase {
  override var extraLaunchArguments: [String] {
    [UITestIdentifiers.readyLaunchArgument, UITestIdentifiers.transcribeSampleLaunchArgument]
  }

  func testTranscribingAFileSavesItUnderItsTitle() {
    let main = mainWindow()
    // The window slides to the new transcript, its turns under each speaker…
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(
          NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", UITestIdentifiers.cannedFileSpeakerA,
            UITestIdentifiers.cannedFileSpeakerA)
        ).firstMatch.waitForExistence(timeout: 15),
      "The window opens the new transcript")
    // …and the entry is saved under the LLM's title.
    let title = UITestIdentifiers.cannedFileTitle
    XCTAssertTrue(
      main.descendants(matching: .any)
        .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", title, title)).firstMatch
        .waitForExistence(timeout: 15),
      "The transcribed file is saved under the LLM's title")
  }
}
