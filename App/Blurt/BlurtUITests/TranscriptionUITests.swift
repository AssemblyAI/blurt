import XCTest

/// The main window's transcription features: the Recent history (its filter,
/// search, ⌘F, opening, deleting), the transcript sheet (speaker turns, Plain
/// text, a task on the LLM), the toolbar's Record and Browse, and the
/// auto-record setting. (Recording itself is in `LiveRecordingUITests`.)
///
/// Runs on the ready screen against a seeded, throwaway history
/// (`-BlurtUITestSeedHistory`: a two-speaker recording, a dictation, a
/// read-aloud clip) and a canned transport standing in for the async API and
/// the LLM Gateway, so nothing touches the network or the user's history.
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
      text(containing: "No results").waitForExistence(timeout: 5), "A search with no matches should say so"
    )
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
      "Meeting notes shows the LLM's result"
    )

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

  /// A kind from the toolbar's Filter menu.
  private func selectFilter(_ title: String) {
    let menu = app.windows[UITestIdentifiers.mainWindowTitle].menuButtons[UITestIdentifiers.libraryFilterMenu]
    XCTAssertTrue(menu.waitForExistence(timeout: 3), "The Filter menu not found")
    menu.click()
    app.menuItems[title].click()
  }
}
