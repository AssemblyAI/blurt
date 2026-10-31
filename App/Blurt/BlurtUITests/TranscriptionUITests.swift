import XCTest

/// The main window's transcription features: the Recent history (its filter,
/// search, ⌘F, opening, deleting), the transcript sheet (speaker turns, Plain
/// text, a task on the LLM), transcribing a file, the drop well's controls, and
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

    selectFilter("Transcripts")
    XCTAssertTrue(row(titled: UITestIdentifiers.seededRecordingTitle).waitForExistence(timeout: 5))
    XCTAssertFalse(row(titled: UITestIdentifiers.seededDictationText).exists, "Transcripts hides dictations")

    selectFilter("Read Aloud")
    XCTAssertTrue(row(titled: UITestIdentifiers.seededReadText).waitForExistence(timeout: 5))
    XCTAssertFalse(row(titled: UITestIdentifiers.seededRecordingTitle).exists, "Read Aloud hides recordings")

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
    let search = app.searchFields[UITestIdentifiers.recentSearchField]
    XCTAssertTrue(search.exists, "The Recent list should have a search field")
    search.typeText("zzqx")
    XCTAssertTrue(
      text(containing: "No results").waitForExistence(timeout: 5), "A search with no matches should say so")
  }

  // MARK: - Transcript sheet

  func testOpeningARecordingShowsSpeakersPlainTextAndATask() {
    mainWindow()
    let recording = row(titled: UITestIdentifiers.seededRecordingTitle)
    XCTAssertTrue(recording.waitForExistence(timeout: 10))
    recording.doubleClick()

    // Full: the turns, each under its speaker.
    XCTAssertTrue(sheetText(containing: "Speaker A").waitForExistence(timeout: 5), "Full shows speaker A's turn")
    XCTAssertTrue(sheetText(containing: "Speaker B").exists, "Full shows speaker B's turn")
    XCTAssertTrue(sheetText(containing: UITestIdentifiers.seededRecordingSpeakerA).exists)

    // Plain text: the same words, no labels.
    chip("plain").click()
    let plain = "\(UITestIdentifiers.seededRecordingSpeakerA) \(UITestIdentifiers.seededRecordingSpeakerB)"
    XCTAssertTrue(sheetText(containing: plain).waitForExistence(timeout: 5), "Plain text shows the unlabelled words")

    // A task: the canned gateway's answer lands in the text area.
    chip("meetingNotes").click()
    XCTAssertTrue(
      sheetText(containing: UITestIdentifiers.cannedTaskResult).waitForExistence(timeout: 10),
      "Meeting notes shows the LLM's result")

    app.windows[UITestIdentifiers.mainWindowTitle].sheets.buttons["Done"].click()
    XCTAssertFalse(chip("full").waitForExistence(timeout: 2), "Done closes the sheet")
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

  func testDropWellControlsAndAutoRecordSetting() {
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

  /// A Recent row by its title. The row is one combined element whose text
  /// ("<title>, <details>") XCUITest may report as its label or its value.
  private func row(titled title: String) -> XCUIElement {
    app.windows[UITestIdentifiers.mainWindowTitle].outlines[UITestIdentifiers.recentList].staticTexts
      .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", title, title)).firstMatch
  }

  /// Static text in the main window containing `text`. A typed query:
  /// matching `.any` element across the window is slow enough on this
  /// hierarchy for XCUITest to time out.
  private func text(containing text: String) -> XCUIElement {
    app.windows[UITestIdentifiers.mainWindowTitle].staticTexts
      .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
  }

  /// Anything in the transcript sheet showing `text`. A speaker turn is one
  /// combined element — a group, not static text — so any type is matched,
  /// which the sheet's small tree keeps fast.
  private func sheetText(containing text: String) -> XCUIElement {
    app.windows[UITestIdentifiers.mainWindowTitle].sheets.firstMatch.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
  }

  /// A transcript sheet chip, by its facet's raw value.
  private func chip(_ facet: String) -> XCUIElement {
    app.windows[UITestIdentifiers.mainWindowTitle].buttons[UITestIdentifiers.facetChipPrefix + facet].firstMatch
  }

  /// A segment of the Recent list's filter. Segmented controls surface as radio
  /// buttons or plain buttons depending on the OS build.
  private func selectFilter(_ title: String) {
    let main = app.windows[UITestIdentifiers.mainWindowTitle]
    let radio = main.radioButtons[title]
    if radio.waitForExistence(timeout: 3) {
      radio.click()
    } else {
      let button = main.buttons[title]
      XCTAssertTrue(button.waitForExistence(timeout: 3), "Filter '\(title)' not found")
      button.click()
    }
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
    // The sheet opens on the new transcript, its turns under each speaker…
    XCTAssertTrue(
      main.sheets.firstMatch.descendants(matching: .any)
        .matching(
          NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", UITestIdentifiers.cannedFileSpeakerA,
            UITestIdentifiers.cannedFileSpeakerA)
        ).firstMatch.waitForExistence(timeout: 15),
      "The sheet opens on the new transcript")
    // …and the entry is saved under the LLM's title.
    let title = UITestIdentifiers.cannedFileTitle
    XCTAssertTrue(
      main.outlines[UITestIdentifiers.recentList].staticTexts
        .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", title, title)).firstMatch
        .waitForExistence(timeout: 15),
      "The transcribed file is saved under the LLM's title")
  }
}
