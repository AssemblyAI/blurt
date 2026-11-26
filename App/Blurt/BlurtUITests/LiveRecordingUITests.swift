import XCTest

/// The toolbar's Record, end to end: live turns streaming in under their
/// speakers, Pause and Resume, Discard asking first, Stop saving and opening
/// the recording under its diarized transcript, and a dropped live session
/// still saving what was said.
///
/// Recording runs on doubles for its two edges (`TranscriptsModel.uiTest(store:)`):
/// a capture that needs none of the microphone and system-audio grants the test
/// host can't give (`UITestRecordingCapture`), and a live session whose scripted
/// turns the harness's Next Turn releases one at a time, or Fail Live drops
/// (`UITestLiveSession`), so each partial and final is read as it lands.
/// Everything between them — the model, the live page, saving, the diarized
/// pass — is the app's own.
final class LiveRecordingUITests: BlurtUITestCase {
  override var extraLaunchArguments: [String] {
    [UITestIdentifiers.readyLaunchArgument, UITestIdentifiers.seedHistoryLaunchArgument]
  }

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
    // On a miss, where things were: whether a window covered Discard….
    XCTAssertTrue(
      confirm.waitForExistence(timeout: 5),
      "Discarding asks first (Discard… at \(discard.frame), hittable \(discard.isHittable); "
        + "main \(main.frame), harness \(harness.frame))"
    )
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

  // MARK: - Helpers

  /// A turn on the live page whose words or speaker contain `text`, scoped
  /// to the main window. Not `.groups`: a `TurnBlock` matched none on CI. Not
  /// app-wide like `windowText`: that timed out ("Timed out while evaluating
  /// UI query") under the live page's ticking clock, while the window-scoped
  /// match passed every run.
  private func liveTurn(containing text: String) -> XCUIElement {
    let window = app.windows[UITestIdentifiers.mainWindowTitle]
    let shown = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
    return window.descendants(matching: .any).matching(shown).firstMatch
  }
}
