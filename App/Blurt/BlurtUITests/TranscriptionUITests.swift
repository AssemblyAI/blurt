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
/// Recording runs on doubles for its two edges (`TranscriptsModel.uiTest(store:)`):
/// a capture that needs none of the microphone and system-audio grants the test
/// host can't give, and a live session whose scripted turns the harness's Next
/// Turn releases one at a time (or Fail Live drops), so each partial and final
/// is read as it lands. Everything between them — the model, the live page,
/// saving, the diarized pass — is the app's own.
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

  // MARK: - Recording

  /// Record streams the session's turns in as they're spoken — a partial, then
  /// its final, each under its speaker — and Stop saves the recording, opens
  /// it, and upgrades the live transcript to the diarized one under its title.
  func testRecordStreamsLiveTurnsThenStopSavesThem() {
    let (harness, main) = readyScreenWindows()
    startLiveRecording(in: main)
    XCTAssertTrue(text(containing: "Listening…").waitForExistence(timeout: 5), "Nothing heard yet")

    releaseLiveTurn(in: harness)
    XCTAssertTrue(
      text(containing: UITestIdentifiers.livePartialA).waitForExistence(timeout: 5),
      "What's being said shows as it's said"
    )
    releaseLiveTurn(in: harness)
    XCTAssertTrue(
      liveTurn(containing: UITestIdentifiers.liveFinalA).waitForExistence(timeout: 5), "The final settles it"
    )
    releaseLiveTurn(in: harness)
    releaseLiveTurn(in: harness)
    XCTAssertTrue(liveTurn(containing: UITestIdentifiers.liveFinalB).waitForExistence(timeout: 5))
    XCTAssertTrue(liveTurn(containing: "Speaker B").exists, "Two speakers: each turn under its speaker")

    main.buttons[UITestIdentifiers.liveRecordingStop].click()
    XCTAssertTrue(viewPicker.waitForExistence(timeout: 15), "Stop saves the recording and opens it")
    XCTAssertTrue(
      windowText(containing: UITestIdentifiers.cannedFileSpeakerA).waitForExistence(timeout: 15),
      "The diarized pass replaces the live transcript"
    )
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      row(titled: UITestIdentifiers.cannedFileTitle).waitForExistence(timeout: 10),
      "The recording is in the Library under its title"
    )
  }

  /// Pause stops the clock and says so; Resume carries on recording.
  func testPauseAndResume() {
    let (_, main) = readyScreenWindows()
    startLiveRecording(in: main)
    let pause = main.buttons[UITestIdentifiers.liveRecordingPause]
    pause.click()
    XCTAssertTrue(text(containing: "Paused").waitForExistence(timeout: 5), "Pause says it's paused")
    pause.click()
    XCTAssertTrue(text(containing: "Recording").waitForExistence(timeout: 5), "Resume says it's recording again")
    XCTAssertFalse(text(containing: "Paused").exists)
  }

  /// Discard… asks first; Escape keeps recording, Discard throws the
  /// recording and what it heard away.
  func testDiscardAsksThenThrowsTheRecordingAway() {
    let (harness, main) = readyScreenWindows()
    startLiveRecording(in: main)
    releaseLiveTurn(in: harness)
    releaseLiveTurn(in: harness)
    XCTAssertTrue(liveTurn(containing: UITestIdentifiers.liveFinalA).waitForExistence(timeout: 5))

    let discard = main.buttons[UITestIdentifiers.liveRecordingDiscard]
    discard.click()
    // Scoped to the window's sheet: a bare "Discard" could match elsewhere.
    let confirm = main.sheets.buttons["Discard"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Discarding asks first")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), "Escape closes the question…")
    XCTAssertTrue(main.buttons[UITestIdentifiers.liveRecordingStop].exists, "…and keeps recording")

    discard.click()
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    confirm.click()
    XCTAssertTrue(
      main.buttons[UITestIdentifiers.liveRecordingStop].waitForNonExistence(timeout: 10), "Discard ends the recording"
    )
    XCTAssertFalse(liveTurn(containing: UITestIdentifiers.liveFinalA).exists, "Nothing of it is kept")
  }

  /// A live session that drops mid-recording ends the recording and still
  /// saves it, rather than losing what was said.
  func testDroppedLiveSessionStillSavesTheRecording() {
    let (harness, main) = readyScreenWindows()
    startLiveRecording(in: main)
    releaseLiveTurn(in: harness)
    releaseLiveTurn(in: harness)
    XCTAssertTrue(liveTurn(containing: UITestIdentifiers.liveFinalA).waitForExistence(timeout: 5))

    harness.buttons[UITestIdentifiers.harnessLiveFail].click()
    XCTAssertTrue(viewPicker.waitForExistence(timeout: 15), "The recording is saved and opened")
    XCTAssertFalse(main.buttons[UITestIdentifiers.liveRecordingStop].exists, "…and is no longer recording")
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

  /// Static text in the main window containing `text`. A typed query:
  /// matching `.any` element across the window is slow enough on this
  /// hierarchy for XCUITest to time out.
  private func text(containing text: String) -> XCUIElement {
    app.windows[UITestIdentifiers.mainWindowTitle].staticTexts
      .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
  }

  /// A turn on the live page whose words or speaker contain `text`: a
  /// `TurnBlock` is one combined element, a group. A typed query on the main
  /// window: `windowText`'s app-wide `.any` match timed out
  /// ("Timed out while evaluating UI query") under the live page's ticking clock.
  private func liveTurn(containing text: String) -> XCUIElement {
    app.windows[UITestIdentifiers.mainWindowTitle].groups
      .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
  }

  /// Anything in the app showing `text` — the open item's transcript. A speaker turn is one combined element — a group,
  /// not static text — so any type is matched.
  private func windowText(containing text: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
  }

  /// A kind from the toolbar's Filter menu.
  private func selectFilter(_ title: String) {
    let menu = app.windows[UITestIdentifiers.mainWindowTitle].menuButtons[UITestIdentifiers.libraryFilterMenu]
    XCTAssertTrue(menu.waitForExistence(timeout: 3), "The Filter menu not found")
    menu.click()
    app.menuItems[title].click()
  }
}
